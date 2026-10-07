#!/usr/bin/env bash
# Install Duendee Tunnel Tool portable (Linux) and put `duendee-tunnel` on PATH.
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash
set -euo pipefail

REPO="${DT_REPO:-hayripenah/Duendee-Tunnel-Tool}"
TAG="${DT_TAG:-latest}"
INSTALL_DIR="${DT_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/duendee-tunnel-tool}"
BIN_DIR="${DT_BIN_DIR:-$HOME/.local/bin}"
ASSET="Duendee-Tunnel-Tool-Linux-portable.tar.gz"
SKIP_NPM="${DT_SKIP_NPM:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need curl
need tar

api_url() {
  if [[ "$TAG" == "latest" ]]; then
    echo "https://api.github.com/repos/${REPO}/releases/latest"
  else
    echo "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  fi
}

echo "Installing Duendee Tunnel Tool -> ${INSTALL_DIR}"

json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: DuendeeTunnelTool-Install' "$(api_url)")"
download_url=""
rel_tag=""
if command -v node >/dev/null 2>&1; then
  download_url="$(printf '%s' "$json" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const r=JSON.parse(d);const n=process.argv[1];const a=(r.assets||[]).find(x=>x.name===n);if(!a)process.exit(2);process.stdout.write(a.browser_download_url)})' "$ASSET" 2>/dev/null || true)"
  rel_tag="$(printf '%s' "$json" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{process.stdout.write(JSON.parse(d).tag_name||"")})' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  download_url="$(printf '%s' "$json" | python3 -c 'import json,sys; r=json.load(sys.stdin); n=sys.argv[1]; a=next((x for x in r.get("assets",[]) if x.get("name")==n), None); assert a, "asset missing"; print(a["browser_download_url"])' "$ASSET" 2>/dev/null || true)"
  rel_tag="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
fi
if [[ -z "$download_url" ]]; then
  download_url="$(printf '%s' "$json" | grep -oE "https://[^\"]+/${ASSET}" | head -n1 || true)"
  rel_tag="$(printf '%s' "$json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"/\1/' || true)"
fi
[[ -n "$download_url" ]] || { echo "Could not find release asset: ${ASSET}" >&2; exit 1; }

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Downloading ${rel_tag:-$TAG}: ${download_url}"
curl -fsSL -o "${tmp}/${ASSET}" "$download_url"
tar -xzf "${tmp}/${ASSET}" -C "$tmp"
extracted="$(find "$tmp" -maxdepth 1 -type d -name 'Duendee-Tunnel-Tool-Linux-portable*' | head -n1)"
[[ -n "$extracted" ]] || { echo "Archive layout unexpected." >&2; exit 1; }

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Preserve user state
for name in config.json .whatsapp-session .tunnelstate; do
  if [[ -e "${INSTALL_DIR}/${name}" ]]; then
    cp -a "${INSTALL_DIR}/${name}" "${tmp}/keep-${name}"
  fi
done

# Replace tree (except preserved paths handled after)
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 \
  ! -name 'config.json' ! -name '.whatsapp-session' ! -name '.tunnelstate' ! -name 'node_modules' \
  -exec rm -rf {} +

cp -a "${extracted}/." "$INSTALL_DIR/"

for name in config.json .whatsapp-session .tunnelstate; do
  if [[ -e "${tmp}/keep-${name}" && ! -e "${INSTALL_DIR}/${name}" ]]; then
    cp -a "${tmp}/keep-${name}" "${INSTALL_DIR}/${name}"
  fi
done

if [[ ! -f "${INSTALL_DIR}/config.json" ]]; then
  cp "${INSTALL_DIR}/config.example.json" "${INSTALL_DIR}/config.json"
  echo "Created config.json from example — edit projectPath before starting."
fi

chmod +x "${INSTALL_DIR}/linux/duendee-tunnel-tool.sh" \
  "${INSTALL_DIR}/linux/scripts/"*.sh 2>/dev/null || true

if [[ "$SKIP_NPM" != "1" ]]; then
  if command -v npm >/dev/null 2>&1; then
    echo "Running npm install (WhatsApp helper)..."
    (cd "$INSTALL_DIR" && npm install --omit=dev || npm install)
  else
    echo "npm not found — install Node.js, then run: npm install  (in ${INSTALL_DIR})"
  fi
fi

shim="${BIN_DIR}/duendee-tunnel"
cat >"$shim" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT="${INSTALL_DIR}"
cd "\$ROOT"
exec bash "\$ROOT/linux/duendee-tunnel-tool.sh" "\$@"
EOF
chmod +x "$shim"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    echo
    echo "Note: ${BIN_DIR} is not on PATH. Add this to ~/.bashrc or ~/.zshrc:"
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    ;;
esac

echo
echo "Install OK (${rel_tag:-$TAG})"
echo "  Location : ${INSTALL_DIR}"
echo "  Run      : duendee-tunnel"
echo "  Edit     : ${INSTALL_DIR}/config.json"

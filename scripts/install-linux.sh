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

install_shim_and_path() {
  mkdir -p "$BIN_DIR"
  local shim="${BIN_DIR}/duendee-tunnel"
  cat >"$shim" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT="${INSTALL_DIR}"
cd "\$ROOT"
exec bash "\$ROOT/linux/duendee-tunnel-tool.sh" "\$@"
EOF
  chmod +x "$shim"

  # Ensure current shell session can find it if this script was sourced
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) export PATH="${BIN_DIR}:${PATH}" ;;
  esac

  # Persist for bash/zsh login shells when missing
  local line="export PATH=\"${BIN_DIR}:\$PATH\""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] || [[ "$rc" == "$HOME/.profile" ]]; then
      touch "$rc"
      if ! grep -Fqs "${BIN_DIR}" "$rc" 2>/dev/null; then
        printf '\n# Duendee Tunnel Tool\n%s\n' "$line" >>"$rc"
        echo "Added ${BIN_DIR} to ${rc}"
        break
      fi
    fi
  done

  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
      echo
      echo "Note: open a new terminal, or run:"
      echo "  export PATH=\"${BIN_DIR}:\$PATH\""
      ;;
  esac
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
cleanup() {
  # Always install shim even if npm/extract partially failed after files exist
  if [[ -d "$INSTALL_DIR" && -f "${INSTALL_DIR}/linux/duendee-tunnel-tool.sh" ]]; then
    install_shim_and_path || true
  fi
  rm -rf "$tmp"
}
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

if [[ ! -f "${INSTALL_DIR}/config.example.json" ]]; then
  echo "Portable archive missing config.example.json" >&2
  exit 1
fi
if [[ ! -f "${INSTALL_DIR}/config.json" ]]; then
  cp "${INSTALL_DIR}/config.example.json" "${INSTALL_DIR}/config.json"
  echo "Created config.json from example — first run will ask for projectPath if needed."
fi

chmod +x "${INSTALL_DIR}/linux/duendee-tunnel-tool.sh" \
  "${INSTALL_DIR}/linux/scripts/"*.sh 2>/dev/null || true

if [[ "$SKIP_NPM" != "1" ]]; then
  if command -v npm >/dev/null 2>&1; then
    echo "Running npm install (WhatsApp helper)..."
    # npm warnings must not abort shim creation (set -e); ignore non-zero only after retry
    set +e
    (cd "$INSTALL_DIR" && npm install --omit=dev)
    npm_ec=$?
    if [[ $npm_ec -ne 0 ]]; then
      (cd "$INSTALL_DIR" && npm install)
      npm_ec=$?
    fi
    set -e
    if [[ $npm_ec -ne 0 ]]; then
      echo "WARNING: npm install failed (exit ${npm_ec}). WhatsApp may need: npm install in ${INSTALL_DIR}"
    fi
  else
    echo "npm not found — install Node.js, then run: npm install  (in ${INSTALL_DIR})"
  fi
fi

# Explicit shim now; trap also ensures it on exit
install_shim_and_path

echo
echo "Install OK (${rel_tag:-$TAG})"
echo "  Location : ${INSTALL_DIR}"
echo "  Run      : duendee-tunnel"
echo "  (New terminal if PATH was just updated, or: export PATH=\"${BIN_DIR}:\$PATH\")"
echo "  Edit     : ${INSTALL_DIR}/config.json"
echo "  WhatsApp : first send shows QR; session saved in .whatsapp-session"

#!/usr/bin/env bash
# Install Duendee Tunnel Tool portable (Linux) and put `duendee-tunnel` on PATH.
#
# Recommended (same terminal session — PATH fix for parent shell after pipe):
#   curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash; export PATH="$HOME/.local/bin:$PATH"; hash -r; duendee-tunnel
#
# Or source into the current shell (PATH export applies immediately):
#   source <(curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh); duendee-tunnel
set -euo pipefail

# Detect `source` / `.` so PATH export applies to the caller shell.
_DT_SOURCED=0
if (return 0 2>/dev/null); then _DT_SOURCED=1; fi

REPO="${DT_REPO:-hayripenah/Duendee-Tunnel-Tool}"
TAG="${DT_TAG:-latest}"
INSTALL_DIR="${DT_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/duendee-tunnel-tool}"
BIN_DIR="${DT_BIN_DIR:-$HOME/.local/bin}"
ASSET="Duendee-Tunnel-Tool-Linux-portable.tar.gz"
SKIP_NPM="${DT_SKIP_NPM:-0}"
PATH_MARKER="# Duendee Tunnel Tool PATH"
PATH_EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
SHIM_PRIMARY=""
SHIM_EXTRA=""

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need curl
need tar

ensure_local_bin_path() {
  export PATH="${HOME}/.local/bin:${PATH}"
}

ensure_node() {
  ensure_local_bin_path
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi
  local node_arch ver="v22.14.0" dest tmp
  case "$(uname -m)" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *)
      echo "Node.js bu mimaride otomatik kurulamadı: $(uname -m)" >&2
      return 1
      ;;
  esac
  dest="${HOME}/.local/share/duendee-node"
  echo "Node.js kuruluyor (${ver}, hesap gerekmez)..."
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "https://nodejs.org/dist/${ver}/node-${ver}-linux-${node_arch}.tar.xz"
  mkdir -p "$dest" "${HOME}/.local/bin"
  tar -xJf "$tmp" -C "$dest" --strip-components=1
  rm -f "$tmp"
  ln -sfn "${dest}/bin/node" "${HOME}/.local/bin/node"
  ln -sfn "${dest}/bin/npm" "${HOME}/.local/bin/npm"
  ln -sfn "${dest}/bin/npx" "${HOME}/.local/bin/npx"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

ensure_cloudflared() {
  ensure_local_bin_path
  if command -v cloudflared >/dev/null 2>&1 || [[ -x "${HOME}/.cloudflared/cloudflared" ]]; then
    return 0
  fi
  local name
  case "$(uname -m)" in
    x86_64|amd64) name="cloudflared-linux-amd64" ;;
    aarch64|arm64) name="cloudflared-linux-arm64" ;;
    *)
      echo "cloudflared bu mimaride otomatik kurulamadı: $(uname -m)" >&2
      return 1
      ;;
  esac
  echo "cloudflared kuruluyor (hesap gerekmez)..."
  mkdir -p "${HOME}/.cloudflared" "${HOME}/.local/bin"
  curl -fsSL -L -o "${HOME}/.cloudflared/cloudflared" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/${name}"
  chmod +x "${HOME}/.cloudflared/cloudflared"
  ln -sfn "${HOME}/.cloudflared/cloudflared" "${HOME}/.local/bin/cloudflared"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

ensure_gh() {
  ensure_local_bin_path
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi
  local name ver="2.102.0" dest tmp
  case "$(uname -m)" in
    x86_64|amd64) name="gh_${ver}_linux_amd64.tar.gz" ;;
    aarch64|arm64) name="gh_${ver}_linux_arm64.tar.gz" ;;
    *)
      echo "GitHub CLI bu mimaride otomatik kurulamadı: $(uname -m)" >&2
      return 1
      ;;
  esac
  echo "GitHub CLI kuruluyor..."
  dest="${HOME}/.local/share/duendee-gh"
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "https://github.com/cli/cli/releases/download/v${ver}/${name}"
  mkdir -p "$dest" "${HOME}/.local/bin"
  tar -xzf "$tmp" -C "$dest" --strip-components=1
  rm -f "$tmp"
  ln -sfn "${dest}/bin/gh" "${HOME}/.local/bin/gh"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

path_has_bin_dir() {
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

api_url() {
  if [[ "$TAG" == "latest" ]]; then
    echo "https://api.github.com/repos/${REPO}/releases/latest"
  else
    echo "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  fi
}

ensure_path_in_rc() {
  local rc="$1"
  touch "$rc"
  # Already configured by us or already mentions this exact bin dir
  if grep -Fqs "$PATH_MARKER" "$rc" 2>/dev/null; then
    return 0
  fi
  if grep -Fqs "$BIN_DIR" "$rc" 2>/dev/null; then
    return 0
  fi
  # Common Ubuntu/Debian idiom: "$HOME/.local/bin" (not expanded)
  if [[ "$BIN_DIR" == "$HOME/.local/bin" ]] && grep -Eqs '(^|[^[:alnum:]_])\$HOME/\.local/bin([^[:alnum:]_]|$)' "$rc" 2>/dev/null; then
    return 0
  fi
  if [[ "$BIN_DIR" == "$HOME/.local/bin" ]] && grep -Eqs '(^|[^[:alnum:]_])~/\.local/bin([^[:alnum:]_]|$)' "$rc" 2>/dev/null; then
    return 0
  fi
  printf '\n%s\n%s\n' "$PATH_MARKER" "$PATH_EXPORT_LINE" >>"$rc"
  echo "Added ${BIN_DIR} to PATH in ${rc}"
}

write_launcher() {
  local dest="$1"
  local src="${INSTALL_DIR}/linux/stable-launch.sh"
  local pointer_dir="${XDG_CONFIG_HOME:-$HOME/.config}/duendee-tunnel"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: missing ${src}" >&2
    return 1
  fi
  mkdir -p "$pointer_dir" "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod +x "$dest" "$src" 2>/dev/null || true
  printf '%s\n' "$INSTALL_DIR" >"${pointer_dir}/root"
}

install_shim_and_path() {
  mkdir -p "$BIN_DIR"
  local shim="${BIN_DIR}/duendee-tunnel"
  local tool_sh="${INSTALL_DIR}/linux/duendee-tunnel-tool.sh"

  if [[ ! -f "$tool_sh" ]]; then
    echo "ERROR: portable tool missing at ${tool_sh}" >&2
    return 1
  fi
  chmod +x "$tool_sh" "${INSTALL_DIR}/linux/scripts/"*.sh 2>/dev/null || true

  write_launcher "$shim"
  if [[ ! -x "$shim" ]]; then
    echo "ERROR: failed to create executable shim at ${shim}" >&2
    return 1
  fi
  SHIM_PRIMARY="$shim"

  # Prefer a dir already on default PATH when writable (helps curl|bash parent shells)
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    write_launcher /usr/local/bin/duendee-tunnel
    SHIM_EXTRA="/usr/local/bin/duendee-tunnel"
    echo "Also installed: ${SHIM_EXTRA} (usually already on PATH)"
  fi

  # Persist for bash / zsh / login shells (update every relevant rc — do not stop at first)
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    if [[ -f "$rc" ]] || [[ "$rc" == "$HOME/.profile" ]] || [[ "$rc" == "$HOME/.bashrc" ]]; then
      ensure_path_in_rc "$rc"
    fi
  done

  # Current process + when sourced into caller
  if ! path_has_bin_dir; then
    export PATH="${BIN_DIR}:${PATH}"
  fi
  hash -r 2>/dev/null || true

  echo "Shim OK: ${shim}"
}

print_path_help() {
  echo
  echo "════════════════════════════════════════════════════════════"
  echo " SAME TERMINAL (curl|bash is a subshell — run this next):"
  echo "   export PATH=\"${BIN_DIR}:\$PATH\"; hash -r; duendee-tunnel"
  echo
  echo " Full one-liner (install + PATH + run):"
  echo "   curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash; export PATH=\"\$HOME/.local/bin:\$PATH\"; hash -r; duendee-tunnel"
  echo
  echo " Or source (PATH applies in this shell immediately):"
  echo "   source <(curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh); duendee-tunnel"
  echo "════════════════════════════════════════════════════════════"
  echo " New terminals: ~/.local/bin was added to bashrc/zshrc/profile when missing."
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
SHIM_DONE=0
cleanup() {
  # Always install shim even if npm/extract partially failed after files exist
  if [[ "$SHIM_DONE" != "1" && -d "$INSTALL_DIR" && -f "${INSTALL_DIR}/linux/duendee-tunnel-tool.sh" ]]; then
    install_shim_and_path || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "Downloading ${rel_tag:-$TAG}: ${download_url}"
curl -fsSL -o "${tmp}/${ASSET}" "$download_url"
tar -xzf "${tmp}/${ASSET}" -C "$tmp"

extracted=""
if [[ -d "${tmp}/Duendee-Tunnel-Tool-Linux-portable" ]]; then
  extracted="${tmp}/Duendee-Tunnel-Tool-Linux-portable"
else
  # Fallback: first directory that contains the Linux entry script
  for cand in "$tmp"/*; do
    if [[ -d "$cand" && -f "${cand}/linux/duendee-tunnel-tool.sh" ]]; then
      extracted="$cand"
      break
    fi
  done
fi
[[ -n "$extracted" ]] || { echo "Archive layout unexpected (linux/duendee-tunnel-tool.sh missing)." >&2; exit 1; }

if [[ ! -f "${extracted}/linux/stable-launch.sh" ]]; then
  echo "Release package is incomplete. Downloading current main (public, no login)..."
  curl -fsSL -o "${tmp}/main.tgz" "https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
  mkdir -p "${tmp}/main-src"
  tar -xzf "${tmp}/main.tgz" -C "${tmp}/main-src"
  for cand in "${tmp}/main-src"/*; do
    if [[ -d "$cand" && -f "${cand}/linux/stable-launch.sh" ]]; then
      extracted="$cand"
      break
    fi
  done
fi
[[ -f "${extracted}/linux/stable-launch.sh" ]] || { echo "Current main is missing linux/stable-launch.sh" >&2; exit 1; }

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

ensure_node || echo "WARNING: Node.js kurulamadı. WhatsApp ve dev server için node gerekli."
ensure_cloudflared || echo "WARNING: cloudflared kurulamadı. Tünel için cloudflared gerekli."
ensure_gh || echo "WARNING: GitHub CLI kurulamadı. Private Duendee indirmek için gh gerekli."

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
SHIM_DONE=1

# Always export for this process; when sourced, caller gets PATH too.
export PATH="${BIN_DIR}:${PATH}"
hash -r 2>/dev/null || true

echo
echo "Install OK (${rel_tag:-$TAG})"
echo "  Location : ${INSTALL_DIR}"
echo "  Shim     : ${SHIM_PRIMARY:-${BIN_DIR}/duendee-tunnel}"
[[ -n "${SHIM_EXTRA:-}" ]] && echo "  Shim+    : ${SHIM_EXTRA}"
echo "  Run      : duendee-tunnel"
if command -v duendee-tunnel >/dev/null 2>&1; then
  echo "  Verified : $(command -v duendee-tunnel)"
else
  echo "  Verified : shim written; parent shell still needs PATH (see below)"
fi
echo "  Edit     : ${INSTALL_DIR}/config.json"
echo "  WhatsApp : first send shows QR; session saved in .whatsapp-session"
print_path_help

if [[ "$_DT_SOURCED" == "1" ]]; then
  echo
  echo "Sourced install: PATH updated in this shell. Try: duendee-tunnel"
  return 0 2>/dev/null || true
fi

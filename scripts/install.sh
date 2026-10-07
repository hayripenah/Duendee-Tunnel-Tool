#!/usr/bin/env bash
# Cross-platform installer entry (Linux / macOS / Git Bash). Windows users: use the PowerShell one-liner.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install.sh | bash
set -euo pipefail

RAW_BASE="${DT_RAW_BASE:-https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main}"

os="$(uname -s 2>/dev/null || echo unknown)"
case "$os" in
  Linux*|linux*|Darwin*|darwin*)
    curl -fsSL "${RAW_BASE}/scripts/install-linux.sh" | bash
    echo
    echo "Next (same terminal): export PATH=\"\$HOME/.local/bin:\$PATH\"; hash -r; duendee-tunnel"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows detected in a Unix shell."
    echo "Prefer PowerShell (recommended):"
    echo "  irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex"
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        "irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex"
      exit $?
    fi
    echo "powershell.exe not found — open PowerShell and run the command above." >&2
    exit 1
    ;;
  *)
    echo "Unsupported OS: ${os}" >&2
    echo "Windows (PowerShell): irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex" >&2
    echo "Linux: curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash" >&2
    exit 1
    ;;
esac

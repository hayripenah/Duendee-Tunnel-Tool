#!/usr/bin/env bash
# Smoke checks for the Linux tree (syntax + cancel contract).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINUX="${ROOT}/linux"
cd "$LINUX"

bash -n duendee-tunnel-tool.sh
bash -n scripts/extract-tunnel-url.sh
bash -n scripts/tunnel-watcher.sh

grep -q 'do_start()' duendee-tunnel-tool.sh
grep -q 'do_uninstall()' duendee-tunnel-tool.sh
grep -q 'Emin misiniz?' duendee-tunnel-tool.sh
grep -q 'do_cancel()' duendee-tunnel-tool.sh
grep -q 'tunnel_running' duendee-tunnel-tool.sh
# Cancel must not call do_start (no auto-restart)
if grep -A20 '^do_cancel()' duendee-tunnel-tool.sh | grep -q 'do_start'; then
  echo "FAIL: do_cancel still calls do_start" >&2
  exit 1
fi
grep -q 'ROOT=' duendee-tunnel-tool.sh
echo "linux checks OK"

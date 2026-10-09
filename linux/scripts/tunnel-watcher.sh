#!/usr/bin/env bash
# Watches the tunnel tool shell; cleans up cloudflared + dev server when it exits.
set -u
TOOL_PID="${1:?ToolPid required}"
PROJECT="${2:?Project required}"
TOOL_ROOT="${3:?ToolRoot required}"
STATE="${TOOL_ROOT}/.tunnelstate"
TUNNEL_PID_FILE="${STATE}/tunnel.pid"
SERVER_PID_FILE="${STATE}/server.pid"
QR_PNG="${TMPDIR:-/tmp}/duendee-whatsapp-qr.png"

while kill -0 "$TOOL_PID" 2>/dev/null; do
  sleep 0.5
done

# The tool terminal is gone. The link message stays only while the tool is running.
wa_js="${TOOL_ROOT}/scripts/send-whatsapp.js"
sent_file="${TOOL_ROOT}/.whatsapp-session/sent-links.json"
creds="${TOOL_ROOT}/.whatsapp-session/creds.json"
if [[ -f "$wa_js" && -f "$sent_file" && -f "$creds" && -s "$sent_file" ]] && ! grep -q '^\[\][[:space:]]*$' "$sent_file"; then
  if command -v node >/dev/null 2>&1; then
    DT_WA_ACTION=retract DT_WA_TIMEOUT_MS=45000 node "$wa_js" --retract || true
  fi
fi

pkill -f "cloudflared tunnel --url" 2>/dev/null || true
killall cloudflared 2>/dev/null || true

for f in "$TUNNEL_PID_FILE" "$SERVER_PID_FILE"; do
  if [[ -f "$f" ]]; then
    id="$(tr -d '[:space:]' < "$f" || true)"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
      kill -TERM "-$id" 2>/dev/null || kill -TERM "$id" 2>/dev/null || true
      sleep 0.2
      kill -KILL "-$id" 2>/dev/null || kill -KILL "$id" 2>/dev/null || true
    fi
  fi
done

# Best-effort: stop the app origin started for this project
for pat in "npm run dev" "vite preview"; do
  pgrep -af "$pat" 2>/dev/null | while read -r line; do
    if [[ "$line" == *"$PROJECT"* ]]; then
      pid="${line%% *}"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
    fi
  done
done

rm -f "$QR_PNG" "$TUNNEL_PID_FILE" "$SERVER_PID_FILE" "${STATE}/tunnel.url" 2>/dev/null || true
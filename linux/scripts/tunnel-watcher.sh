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

# Best-effort: stop npm run dev started for this project
pgrep -af "npm run dev" 2>/dev/null | while read -r line; do
  if [[ "$line" == *"$PROJECT"* ]]; then
    pid="${line%% *}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
  fi
done

rm -f "$QR_PNG" "$TUNNEL_PID_FILE" "$SERVER_PID_FILE" "${STATE}/tunnel.url" 2>/dev/null || true
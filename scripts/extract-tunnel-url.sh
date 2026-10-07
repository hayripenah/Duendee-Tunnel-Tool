#!/usr/bin/env bash
# Extract latest Cloudflare quick-tunnel URL from cloudflared logs.
set -u
LOG="${1:-}"
OUT_LOG="${2:-}"
URL_FILE="${3:?UrlFile required}"
PATTERN='https://[a-zA-Z0-9\-]+\.(trycloudflare\.com|cfargotunnel\.com)'

blob=""
for path in "$OUT_LOG" "$LOG"; do
  [[ -n "$path" && -f "$path" ]] || continue
  # strip ANSI
  blob+=$'\n'"$(sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' "$path" 2>/dev/null || cat "$path")"
done

url="$(printf '%s' "$blob" | grep -Eo "$PATTERN" | tail -n 1 | tr -d '\r' | sed 's|[|/]*$||')"
[[ -n "$url" ]] || exit 1

mkdir -p "$(dirname "$URL_FILE")"
printf '%s' "$url" > "$URL_FILE"
printf '%s\n' "$url"
exit 0
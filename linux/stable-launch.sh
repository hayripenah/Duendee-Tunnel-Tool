#!/usr/bin/env bash
# Stable launcher. Lives outside the tool folder so a moved repo still opens.
set -u
POINTER="${XDG_CONFIG_HOME:-$HOME/.config}/duendee-tunnel/root"
HITFILE="$(mktemp)"
trap 'rm -f "$HITFILE"' EXIT

is_tool() {
  [[ -n "${1:-}" && -f "$1/linux/duendee-tunnel-tool.sh" && -f "$1/config.example.json" ]]
}

add_hit() {
  is_tool "$1" || return 0
  local full
  full="$(cd "$1" && pwd)" || return 0
  grep -Fxq "$full" "$HITFILE" 2>/dev/null && return 0
  printf '%s\n' "$full" >>"$HITFILE"
}

search_base() {
  local base="$1" depth="$2" filter="$3" d name
  [[ -d "$base" ]] || return 0
  add_hit "$base"
  [[ "$depth" -le 0 ]] && return 0
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ "$filter" == "1" && ! "$name" =~ Duendee|Tunnel|YEK|Cursor ]]; then
      continue
    fi
    search_base "${d%/}" "$((depth - 1))" 1
  done
}

saved=""
if [[ -f "$POINTER" ]]; then
  saved="$(tr -d '\r' <"$POINTER" | head -n 1 || true)"
  add_hit "$saved"
fi

if [[ ! -s "$HITFILE" && -n "$saved" ]]; then
  search_base "$(dirname "$saved")" 3 0
fi
if [[ ! -s "$HITFILE" ]]; then
  desktop=""
  if [[ -d "$HOME/Desktop" ]]; then desktop="$HOME/Desktop"
  elif [[ -d "$HOME/Masaüstü" ]]; then desktop="$HOME/Masaüstü"
  fi
  share="${XDG_DATA_HOME:-$HOME/.local/share}/duendee-tunnel-tool"
  search_base "$share" 1 0
  search_base "$HOME/YEK/Cursor" 3 0
  search_base "${desktop:+$desktop/YEK/Cursor}" 3 0
  search_base "$HOME/YEK" 3 0
  search_base "${desktop:+$desktop/YEK}" 3 0
  search_base "$HOME/Cursor" 3 0
  search_base "${desktop:+$desktop/Cursor}" 3 0
  [[ -n "$desktop" ]] && search_base "$desktop" 3 0
  search_base "$HOME/Documents" 3 0
  search_base "$HOME" 2 0
fi

pick_newest() {
  local best="" best_m=0 line m
  [[ -s "$HITFILE" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    m="$(stat -c %Y "$line/linux/duendee-tunnel-tool.sh" 2>/dev/null || echo 0)"
    if [[ -z "$best" || "$m" -gt "$best_m" ]]; then
      best="$line"
      best_m="$m"
    fi
  done <"$HITFILE"
  printf '%s\n' "$best"
}

root=""
if is_tool "$saved"; then
  root="$(cd "$saved" && pwd)"
elif [[ -s "$HITFILE" ]]; then
  root="$(pick_newest)"
fi

if [[ -z "$root" ]]; then
  echo "Duendee Tunnel Tool bulunamadi." >&2
  echo "Araci yeni klasorunden bir kez acin; komut yolu kendisi guncellenir." >&2
  exit 1
fi

mkdir -p "$(dirname "$POINTER")"
printf '%s\n' "$root" >"$POINTER"
cd "$root"
exec bash "$root/linux/duendee-tunnel-tool.sh" "$@"

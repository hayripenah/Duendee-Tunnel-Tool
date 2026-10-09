#!/usr/bin/env bash
# Duendee Tunnel Tool (Linux)
# Mirrors the Windows .bat menu: start/status/copy/cancel/shutdown/autostart/uninstall.
set -u
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${OS_DIR}/.." && pwd)"
TOOL="$OS_DIR"
# Shared runtime (config, state, WhatsApp) lives at repo root.
STATE="${ROOT}/.tunnelstate"
PID_FILE="${STATE}/tunnel.pid"
URL_FILE="${STATE}/tunnel.url"
LOG="${STATE}/tunnel.log"
OUT_LOG="${STATE}/tunnel.out.log"
SERVER_PID="${STATE}/server.pid"
WHATSAPP_JS="${ROOT}/scripts/send-whatsapp.js"
# XDG autostart mirrors Windows HKCU\...\Run (opens tool on graphical login).
AUTO_DESKTOP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
AUTO_DESKTOP="${AUTO_DESKTOP_DIR}/duendee-tunnel-tool.desktop"
# Legacy systemd user unit from earlier Linux builds — cleaned up on toggle.
AUTO_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUTO_UNIT="${AUTO_UNIT_DIR}/duendee-tunnel-tool.service"
AUTO=""

RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYN=$'\033[96m'
YEL=$'\033[93m'
GRN=$'\033[92m'
RED=$'\033[91m'
BLUE=$'\033[38;2;59;130;246m'
SKY=$'\033[38;2;147;197;253m'
# Claude Code–style warm salmon for the DUENDEE banner
SALMON=$'\033[38;2;232;113;90m'

mkdir -p "$STATE"

die() {
  echo -e "  ${RED}${BOLD}[HATA]${RST} $*"
  exit 1
}

DUENDEE_REPO_URL="${DT_DUENDEE_REPO_URL:-https://github.com/hayripenah/Duendee.git}"
DUENDEE_CLONE_NAME="${DT_DUENDEE_CLONE_NAME:-Duendee-main}"

save_config() {
  local proj="$1"
  local port="$2"
  local cfg="${ROOT}/config.json"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.dump({"projectPath":sys.argv[1],"port":int(sys.argv[2])}, open(sys.argv[3],"w",encoding="utf-8"), indent=2); open(sys.argv[3],"a",encoding="utf-8").write("\n")' \
      "$proj" "$port" "$cfg"
  elif command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs"); const o={projectPath:process.argv[1],port:Number(process.argv[2])||8080}; fs.writeFileSync(process.argv[3], JSON.stringify(o,null,2)+"\n")' \
      "$proj" "$port" "$cfg"
  else
    printf '{\n  "projectPath": "%s",\n  "port": %s\n}\n' "$proj" "$port" >"$cfg"
  fi
}

read_config_fields() {
  local cfg="$1"
  if command -v python3 >/dev/null 2>&1; then
    PROJECT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("projectPath",""))' "$cfg")"
    PORT="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1],encoding="utf-8")); print(c.get("port") or 8080)' "$cfg")"
  elif command -v node >/dev/null 2>&1; then
    PROJECT="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.projectPath||""))' "$cfg")"
    PORT="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.port||8080))' "$cfg")"
  else
    die "config.json okumak için python3 veya node gerekli."
  fi
}

desktop_dir() {
  local d=""
  if [[ -n "${XDG_DESKTOP_DIR:-}" ]]; then
    d="${XDG_DESKTOP_DIR/#\~/$HOME}"
  elif [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" ]]; then
    # shellcheck disable=SC1090
    d="$(. "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" >/dev/null 2>&1; printf '%s' "${XDG_DESKTOP_DIR:-}")"
    d="${d/#\~/$HOME}"
  fi
  if [[ -z "$d" || ! -d "$d" ]]; then
    for cand in "$HOME/Desktop" "$HOME/Masaüstü" "$HOME/desktop"; do
      if [[ -d "$cand" ]]; then d="$cand"; break; fi
    done
  fi
  if [[ -z "$d" ]]; then
    d="$HOME/Desktop"
    mkdir -p "$d"
  fi
  printf '%s' "$d"
}

looks_like_duendee() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  local leaf base pkg remote
  leaf="$(basename "$path")"
  local name_hit=0 pkg_hit=0 remote_hit=0
  [[ "$leaf" =~ ^[Dd]uendee(-main)?$ ]] && name_hit=1
  pkg="$path/package.json"
  if [[ -f "$pkg" ]]; then
    if grep -Eqi 'hayripenah|dev:tunnel|vite_react_shadcn' "$pkg" 2>/dev/null; then
      pkg_hit=1
    elif grep -Eq '"dev"[[:space:]]*:[[:space:]]*"vite"' "$pkg" 2>/dev/null && (( name_hit )); then
      pkg_hit=1
    fi
  fi
  if [[ -d "$path/.git" ]] && command -v git >/dev/null 2>&1; then
    remote="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" =~ [Gg]ithub\.com[:/].*[Hh]ayripenah/[Dd]uendee(\.git)?/?$ ]]; then
      remote_hit=1
    elif [[ "$remote" =~ /[Dd]uendee(\.git)?/?$ ]] && [[ ! "$remote" =~ [Tt]unnel-[Tt]ool ]]; then
      remote_hit=1
    fi
  fi
  (( remote_hit )) && return 0
  (( name_hit && pkg_hit )) && return 0
  (( pkg_hit )) && [[ -d "$path/.git" ]] && return 0
  return 1
}

update_duendee_safe() {
  local path="$1"
  [[ -d "$path/.git" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]]; then
    echo -e "  ${DIM}   Git: yerel değişiklikler var — pull atlandı (${path})${RST}" >&2
    return 0
  fi
  echo -e "  ${DIM}   Duendee güncelleniyor (git fetch/pull --ff-only)...${RST}" >&2
  if git -C "$path" fetch --quiet 2>/dev/null && git -C "$path" pull --ff-only --quiet 2>/dev/null; then
    echo -e "  ${GRN}   Repo güncel.${RST}" >&2
  else
    echo -e "  ${YEL}   Pull atlandı/başarısız (ff-only). Mevcut kopya kullanılacak.${RST}" >&2
  fi
}

find_local_duendee() {
  local desktop home docs
  desktop="$(desktop_dir)"
  home="$HOME"
  docs="${XDG_DOCUMENTS_DIR:-$HOME/Documents}"
  docs="${docs/#\~/$HOME}"
  local -a bases=(
    "$desktop" "$home" "$docs"
    "$home/YEK/Cursor" "$desktop/YEK/Cursor"
    "$home/Cursor" "$desktop/Cursor"
    "$home/YEK" "$desktop/YEK"
  )
  local -a names=(Duendee-main Duendee duendee-main duendee)
  local -a hits=()
  local seen="" b n p child

  add_hit() {
    local cand="$1"
    [[ -d "$cand" ]] || return 0
    cand="$(cd "$cand" && pwd)"
    case " $seen " in
      *" $cand "*) return 0 ;;
    esac
    if looks_like_duendee "$cand"; then
      hits+=("$cand")
      seen+=" $cand"
    fi
  }

  [[ -n "${DT_DUENDEE_DIR:-}" ]] && add_hit "$DT_DUENDEE_DIR"
  for b in "${bases[@]}"; do
    [[ -d "$b" ]] || continue
    for n in "${names[@]}"; do
      add_hit "$b/$n"
    done
    for child in "$b"/*; do
      [[ -d "$child" ]] || continue
      n="$(basename "$child")"
      if [[ "$n" =~ ^[Dd]uendee(-main)?$ ]]; then
        add_hit "$child"
      fi
      if [[ -d "$child/Cursor" ]]; then
        for n in "${names[@]}"; do
          add_hit "$child/Cursor/$n"
        done
      fi
    done
  done

  if ((${#hits[@]})); then
    printf '%s\n' "${hits[@]}"
  fi
}

pick_dir_gui() {
  local title="${1:-Duendee proje klasörünü seçin}"
  if command -v zenity >/dev/null 2>&1; then
    zenity --file-selection --directory --title="$title" 2>/dev/null || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --getexistingdirectory "$HOME" --title "$title" 2>/dev/null || true
  elif command -v yad >/dev/null 2>&1; then
    yad --file --directory --title="$title" 2>/dev/null || true
  fi
}

clone_duendee_to() {
  local parent="$1"
  local target
  if ! command -v git >/dev/null 2>&1; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} git bulunamadı. Git kurun veya Duendee klasörünü elle seçin." >&2
    return 1
  fi
  mkdir -p "$parent"
  target="${parent%/}/${DUENDEE_CLONE_NAME}"
  if [[ -d "$target" ]]; then
    if looks_like_duendee "$target"; then
      update_duendee_safe "$target"
      (cd "$target" && pwd)
      return 0
    fi
    echo -e "  ${YEL}   Klasör zaten var ama Duendee görünmüyor: ${target}${RST}" >&2
    return 1
  fi
  echo -e "  ${DIM}   Klonlanıyor: ${DUENDEE_REPO_URL} -> ${target}${RST}" >&2
  if git clone --depth 1 "$DUENDEE_REPO_URL" "$target"; then
    (cd "$target" && pwd)
    return 0
  fi
  echo -e "  ${RED}   Clone başarısız.${RST}" >&2
  return 1
}

resolve_project_path_interactive() {
  local current="${1:-}"
  local desktop choice picked cloned i path
  desktop="$(desktop_dir)"
  echo -e "  ${YEL}${BOLD}[KURULUM]${RST} Duendee proje klasörü (projectPath)." >&2
  echo -e "  ${DIM}   Varsayılan konum: Desktop (${desktop})${RST}" >&2
  if [[ -n "$current" && ! -d "$current" ]]; then
    echo -e "  ${DIM}   Mevcut config değeri geçersiz: ${current}${RST}" >&2
  fi
  echo >&2

  mapfile -t found < <(find_local_duendee)
  if ((${#found[@]})); then
    echo -e "  ${GRN}   Yerel Duendee bulundu:${RST}" >&2
    for i in "${!found[@]}"; do
      echo -e "  ${DIM}   [$((i + 1))] ${found[$i]}${RST}" >&2
    done
    echo >&2
    echo -e "  ${DIM}   Enter = [1] kullan ve güncelle | numara | C = özel yol | B = klasör seç | G = Desktop'a klonla${RST}" >&2
    printf '  seçim> '
    read -r choice
    choice="${choice//\"/}"
    if [[ -z "$choice" || "$choice" == "1" ]]; then
      update_duendee_safe "${found[0]}"
      RESOLVED_PROJECT="${found[0]}"
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      i=$((choice - 1))
      if (( i >= 0 && i < ${#found[@]} )); then
        update_duendee_safe "${found[$i]}"
        RESOLVED_PROJECT="${found[$i]}"
        return 0
      fi
    fi
    if [[ "$choice" =~ ^[Gg]$ ]]; then
      cloned="$(clone_duendee_to "$desktop" || true)"
      [[ -n "$cloned" ]] && { RESOLVED_PROJECT="$cloned"; return 0; }
    fi
    if [[ "$choice" =~ ^[Bb]$ ]]; then
      picked="$(pick_dir_gui)"
      if [[ -n "$picked" && -d "$picked" ]]; then
        looks_like_duendee "$picked" && update_duendee_safe "$picked"
        RESOLVED_PROJECT="$(cd "$picked" && pwd)"
        return 0
      fi
    fi
  else
    echo -e "  ${YEL}   Yerel Duendee bulunamadı.${RST}" >&2
    echo -e "  ${DIM}   Enter = Desktop'a klonla (${desktop}/${DUENDEE_CLONE_NAME})${RST}" >&2
    echo -e "  ${DIM}   C = özel klasör yolu | B = klasör seçici | yol yaz = o dizine klonla/kullan${RST}" >&2
    printf '  seçim> '
    read -r choice
    choice="${choice//\"/}"
    choice="${choice/#\~/$HOME}"
    if [[ -z "$choice" || "$choice" =~ ^[Gg]$ ]]; then
      cloned="$(clone_duendee_to "$desktop" || true)"
      [[ -n "$cloned" ]] && { RESOLVED_PROJECT="$cloned"; return 0; }
    elif [[ "$choice" =~ ^[Bb]$ ]]; then
      picked="$(pick_dir_gui)"
      if [[ -n "$picked" && -d "$picked" ]]; then
        if looks_like_duendee "$picked"; then
          update_duendee_safe "$picked"
          RESOLVED_PROJECT="$(cd "$picked" && pwd)"
          return 0
        fi
        cloned="$(clone_duendee_to "$picked" || true)"
        [[ -n "$cloned" ]] && { RESOLVED_PROJECT="$cloned"; return 0; }
      fi
    elif [[ ! "$choice" =~ ^[Cc]$ ]]; then
      if [[ -d "$choice" ]]; then
        if looks_like_duendee "$choice"; then
          update_duendee_safe "$choice"
          RESOLVED_PROJECT="$(cd "$choice" && pwd)"
          return 0
        fi
        cloned="$(clone_duendee_to "$choice" || true)"
        [[ -n "$cloned" ]] && { RESOLVED_PROJECT="$cloned"; return 0; }
      fi
    fi
  fi

  while true; do
    echo -e "  ${DIM}   Özel yol: mevcut Duendee klasörü veya klon ana dizini (boş = Desktop)${RST}" >&2
    printf '  projectPath> '
    read -r entered
    entered="${entered//\"/}"
    entered="${entered/#\~/$HOME}"
    if [[ -z "$entered" ]]; then
      entered="$desktop"
    fi
    if [[ "$entered" =~ ^[Bb]$ ]]; then
      picked="$(pick_dir_gui)"
      [[ -z "$picked" ]] && continue
      entered="$picked"
    fi
    if [[ -d "$entered" ]]; then
      if looks_like_duendee "$entered"; then
        update_duendee_safe "$entered"
        RESOLVED_PROJECT="$(cd "$entered" && pwd)"
        return 0
      fi
      if looks_like_duendee "${entered%/}/${DUENDEE_CLONE_NAME}"; then
        update_duendee_safe "${entered%/}/${DUENDEE_CLONE_NAME}"
        RESOLVED_PROJECT="$(cd "${entered%/}/${DUENDEE_CLONE_NAME}" && pwd)"
        return 0
      fi
      cloned="$(clone_duendee_to "$entered" || true)"
      if [[ -n "$cloned" ]]; then
        RESOLVED_PROJECT="$cloned"
        return 0
      fi
      echo -e "  ${YEL}   Bu klasör Duendee değil ve klon başarısız.${RST}" >&2
      continue
    fi
    echo -e "  ${YEL}   Klasör bulunamadı: ${entered}${RST}" >&2
  done
}

load_config() {
  local cfg="${ROOT}/config.json"
  local example="${ROOT}/config.example.json"
  if [[ ! -f "$cfg" ]]; then
    [[ -f "$example" ]] || die "config.example.json bulunamadı. Portable paket bozuk olabilir."
    cp "$example" "$cfg"
    echo -e "  ${GRN}   config.json oluşturuldu (config.example.json kopyası).${RST}"
    echo
  fi
  read_config_fields "$cfg"
  PORT="${PORT:-8080}"
  if [[ -n "${DT_DUENDEE_DIR:-}" && -d "${DT_DUENDEE_DIR}" ]]; then
    PROJECT="$(cd "${DT_DUENDEE_DIR}" && pwd)"
  fi
  local needs_setup=0
  if [[ -z "${PROJECT:-}" ]]; then
    needs_setup=1
  elif [[ "$PROJECT" == *"/path/to/your/app"* || "$PROJECT" == *"\\path\\to\\your\\app"* ]]; then
    needs_setup=1
  elif [[ ! -d "$PROJECT" ]]; then
    needs_setup=1
  fi
  if (( needs_setup )); then
    resolve_project_path_interactive "${PROJECT:-}"
    PROJECT="$RESOLVED_PROJECT"
    printf '  port [%s]> ' "$PORT"
    read -r port_in
    if [[ "$port_in" =~ ^[0-9]+$ ]]; then
      PORT="$port_in"
    fi
    save_config "$PROJECT" "$PORT"
    echo -e "  ${GRN}   Kaydedildi: ${cfg}${RST}"
    echo -e "  ${GRN}   projectPath = ${PROJECT}${RST}"
    echo
  elif looks_like_duendee "$PROJECT"; then
    update_duendee_safe "$PROJECT"
  fi
  [[ -d "$PROJECT" ]] || die "projectPath bulunamadı: $PROJECT"
  PORT="${PORT:-8080}"
}

ensure_whatsapp_deps() {
  local marker="${ROOT}/node_modules/@whiskeysockets/baileys/package.json"
  [[ -f "$marker" ]] && return 0
  command -v npm >/dev/null 2>&1 || return 1
  echo -e "  ${DIM}   WhatsApp bağımlılıkları kuruluyor (npm install)...${RST}"
  (cd "$ROOT" && npm install --omit=dev) || (cd "$ROOT" && npm install) || return 1
  [[ -f "$marker" ]]
}

send_tunnel_whatsapp() {
  local public_url="${1:-}"
  if [[ ! -f "$WHATSAPP_JS" ]]; then
    echo -e "  ${YEL}   WhatsApp scripti yok: ${WHATSAPP_JS}${RST}"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo -e "  ${YEL}   node bulunamadı — WhatsApp gönderilemedi. Node.js kurup tekrar deneyin.${RST}"
    return 0
  fi
  if ! ensure_whatsapp_deps; then
    echo -e "  ${YEL}   WhatsApp paketleri eksik. Kurulum: cd \"${ROOT}\" && npm install${RST}"
    return 0
  fi
  if [[ -z "$public_url" || "$public_url" != https://* ]]; then
    echo -e "  ${YEL}   Geçerli tünel URL'si yok; WhatsApp atlandı.${RST}"
    return 0
  fi
  local phone=""
  local wa_cfg="${ROOT}/scripts/whatsapp-config.json"
  if [[ -f "$wa_cfg" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      phone="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("targetPhone",""))' "$wa_cfg" 2>/dev/null || true)"
    elif command -v node >/dev/null 2>&1; then
      phone="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.targetPhone||""))' "$wa_cfg" 2>/dev/null || true)"
    fi
  fi
  if [[ ! -f "${ROOT}/.whatsapp-session/creds.json" ]]; then
    echo -e "  ${YEL}   WhatsApp hatti ${phone:-5315162429} bagli degil. Yeni QR olusturuluyor.${RST}"
    echo -e "  ${DIM}   WhatsApp > Bagli Cihazlar > Cihaz Bagla. Tarama sonrasi link gider.${RST}"
  else
    echo "  WhatsApp hatti kontrol ediliyor (${phone:-5315162429})..."
  fi
  echo "  WhatsApp'a link gönderiliyor..."
  local ec=0
  export DT_WA_URL="$public_url"
  export DT_WA_PHONE="$phone"
  if [[ -n "$phone" ]]; then
    node "$WHATSAPP_JS" "$public_url" "$phone" || ec=$?
  else
    node "$WHATSAPP_JS" "$public_url" || ec=$?
  fi
  unset DT_WA_URL DT_WA_PHONE
  if (( ec != 0 )); then
    echo -e "  ${YEL}   WhatsApp gönderimi başarısız (çıkış ${ec}).${RST}"
    echo -e "  ${DIM}   QR tarayin veya: rm -rf \"${ROOT}/.whatsapp-session\" sonra tekrar.${RST}"
    echo -e "  ${DIM}   Manuel: node \"${WHATSAPP_JS}\" \"${public_url}\"${RST}"
  else
    echo -e "  ${GRN}   WhatsApp mesaji gonderildi.${RST}"
  fi
}

retract_tunnel_whatsapp() {
  local wa_js="${WHATSAPP_JS:-${ROOT}/scripts/send-whatsapp.js}"
  local sent_file="${ROOT}/.whatsapp-session/sent-links.json"
  local creds="${ROOT}/.whatsapp-session/creds.json"
  [[ -f "$wa_js" && -f "$sent_file" && -f "$creds" ]] || return 0
  if [[ ! -s "$sent_file" ]] || grep -q '^\[\][[:space:]]*$' "$sent_file"; then
    return 0
  fi
  command -v node >/dev/null 2>&1 || return 0
  ensure_whatsapp_deps || return 0
  echo "  Eski tunnel linki mesajlari kaldiriliyor..."
  local ec=0
  DT_WA_ACTION=retract DT_WA_TIMEOUT_MS="${DT_WA_TIMEOUT_MS:-45000}" node "$wa_js" || ec=$?
  if (( ec != 0 )); then
    echo -e "  ${YEL}   Eski WhatsApp link mesaji kaldirilamadi (çıkış ${ec}).${RST}"
  else
    echo -e "  ${GRN}   Gecersiz tunnel linki mesaji kaldirildi.${RST}"
  fi
}

find_cloudflared() {
  if [[ -n "${DT_CF:-}" ]]; then
    CF="$DT_CF"
    return 0
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    CF="$(command -v cloudflared)"
    return 0
  fi
  for p in "$HOME/.cloudflared/cloudflared" /usr/local/bin/cloudflared /usr/bin/cloudflared; do
    if [[ -x "$p" ]]; then
      CF="$p"
      return 0
    fi
  done
  return 1
}

read_pid() {
  TPID=""
  if [[ -f "$PID_FILE" ]]; then
    TPID="$(tr -d '[:space:]' < "$PID_FILE" || true)"
  fi
}

pid_alive() {
  local id="${1:-}"
  [[ -n "$id" ]] && kill -0 "$id" 2>/dev/null
}

port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | grep -q LISTEN && return 0
    ss -ltn 2>/dev/null | grep -E ":${port}\\b" | grep -q LISTEN && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -E ":${port}\\b" | grep -q LISTEN && return 0
  fi
  return 1
}

copy_clipboard() {
  local text="$1"
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy && return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard && return 0
  fi
  if command -v xsel >/dev/null 2>&1; then
    printf '%s' "$text" | xsel --clipboard --input && return 0
  fi
  return 1
}

open_url() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v sensible-browser >/dev/null 2>&1; then
    sensible-browser "$url" >/dev/null 2>&1 || true
  fi
}

http_code() {
  local target="$1"
  local timeout="${2:-4}"
  curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" "$target" 2>/dev/null || echo "000"
}

extract_url() {
  bash "${OS_DIR}/scripts/extract-tunnel-url.sh" "$LOG" "$OUT_LOG" "$URL_FILE" >/dev/null 2>&1 || true
}

refresh_url() {
  PREV="${URL:-}"
  URL=""
  extract_url
  if [[ -f "$URL_FILE" ]]; then
    URL="$(tr -d '\r\n' < "$URL_FILE" || true)"
  fi
  if [[ -z "$URL" && -n "${PREV:-}" && -f "$URL_FILE" ]]; then
    URL="$PREV"
  fi
  [[ -n "${URL:-}" ]] && TUNNEL_URL="$URL"
}

short_log_line() {
  local t="$1"
  t="${t#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T* }"
  t="${t#ERR }"
  t="${t#WRN }"
  t="${t#INF }"
  case "$t" in
    *'Registered tunnel connection'*) printf '%s\n' 'Tünel bağlandı'; return ;;
    *'quick Tunnel has been created'*|*'Requesting new quick Tunnel'*) printf '%s\n' 'Hızlı tünel açıldı'; return ;;
    *'Unable to reach the origin'*|*'connection refused'*) printf '%s\n' 'Yerel sunucuya ulaşılamadı'; return ;;
    *'failed to serve tunnel'*|*'connection terminated'*|*'context canceled'*) printf '%s\n' 'Tünel kesildi'; return ;;
  esac
  case "$t" in
    '+'*|'|'*|*'Thank you for trying'*|*'no uptime guarantee'*|*'Cannot determine default'*|*'GOOS:'*|*'GoArch:'*|*'Settings:'*|*'automatically update'*|*'Generated Connector'*|*'Initial protocol'*|*'ICMP proxy'*|*'metrics server'*|'Version '*) return 0 ;;
  esac
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [[ -n "$t" ]] || return 0
  if ((${#t} > 64)); then
    t="${t:0:61}..."
  fi
  printf '%s\n' "$t"
}

logtail() {
  local brief="${1:-}"
  echo -e "  ${DIM}   Son log:${RST}"
  if [[ ! -f "$LOG" ]]; then
    return 0
  fi
  if [[ "$brief" == "brief" ]]; then
    local -a shown=()
    local s short seen
    while IFS= read -r s; do
      short="$(short_log_line "$s" || true)"
      [[ -n "$short" ]] || continue
      seen=0
      for prev in "${shown[@]+"${shown[@]}"}"; do
        [[ "$prev" == "$short" ]] && seen=1 && break
      done
      [[ "$seen" == "1" ]] && continue
      shown+=("$short")
    done < <(tail -n 24 "$LOG" 2>/dev/null || true)
    local i start=${#shown[@]}
    if (( start > 4 )); then start=$((${#shown[@]} - 4)); else start=0; fi
    for ((i = start; i < ${#shown[@]}; i++)); do
      echo "    ${shown[$i]}"
    done
    return 0
  fi
  tail -n 8 "$LOG" 2>/dev/null | while IFS= read -r s; do
    t="$s"
    t="${t/#ERR /Hata: }"
    t="${t/#WRN /Uyarı: }"
    t="${t/#INF /Bilgi: }"
    t="${t//precheck complete/ön kontrol tamamlandı}"
    t="${t//Registered tunnel connection/tünel bağlantısı kuruldu}"
    t="${t//Unable to reach the origin/yerel sunucu (origin) erişilemiyor}"
    t="${t//connection refused/bağlantı reddedildi}"
    t="${t//error=/hata=}"
    if [[ "$s" == ERR* ]]; then
      echo -e "    ${RED}${t}${RST}"
    elif [[ "$s" == WRN* ]]; then
      echo -e "    ${YEL}${t}${RST}"
    elif [[ "$s" == INF* ]]; then
      echo -e "    ${GRN}${t}${RST}"
    else
      echo -e "    ${DIM}${t}${RST}"
    fi
  done
}

autostate() {
  # off | tool | tunnel
  AUTOMODE=off
  local enabled=0
  if systemctl --user is-enabled duendee-tunnel-tool.service >/dev/null 2>&1; then
    enabled=1
  elif [[ -f "$AUTO_UNIT" ]]; then
    enabled=1
  fi
  if [[ "$enabled" == "1" ]]; then
    if [[ -f "$AUTO_UNIT" ]] && grep -q 'boot-tunnel' "$AUTO_UNIT"; then
      AUTOMODE=tunnel
    else
      AUTOMODE=tool
    fi
  fi
}

start_watcher() {
  local tool_pid="$$"
  # ToolRoot = repo root (shared .tunnelstate)
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "${OS_DIR}/scripts/tunnel-watcher.sh" "$tool_pid" "$PROJECT" "$ROOT" \
      >/dev/null 2>&1 &
  else
    nohup bash "${OS_DIR}/scripts/tunnel-watcher.sh" "$tool_pid" "$PROJECT" "$ROOT" \
      >/dev/null 2>&1 &
  fi
}

tunnel_running() {
  read_pid
  if [[ -n "${TPID:-}" ]] && pid_alive "$TPID"; then
    return 0
  fi
  pgrep -f "cloudflared tunnel --url" >/dev/null 2>&1 && return 0
  return 1
}

kill_tunnel() {
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      kill -TERM "-$TPID" 2>/dev/null || kill -TERM "$TPID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-$TPID" 2>/dev/null || kill -KILL "$TPID" 2>/dev/null || true
      echo -e "  ${GRN}   Tünel durduruldu - PID ${TPID}.${RST}"
    fi
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -f "$PID_FILE" "$URL_FILE"
}

kill_dev_server() {
  local spid=""
  local stopped=0
  if [[ -f "$SERVER_PID" ]]; then
    spid="$(tr -d '[:space:]' < "$SERVER_PID" || true)"
  fi
  if [[ -n "$spid" ]]; then
    if pid_alive "$spid"; then
      # Kill process group (setsid npm/node tree)
      kill -TERM "-$spid" 2>/dev/null || kill -TERM "$spid" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-$spid" 2>/dev/null || kill -KILL "$spid" 2>/dev/null || true
      echo -e "  ${GRN}   Dev server durduruldu - PID ${spid}.${RST}"
      stopped=1
    fi
    rm -f "$SERVER_PID"
  fi
  # Fallback: npm run dev started for this project
  if [[ -n "${PROJECT:-}" ]]; then
    pgrep -af "npm run dev" 2>/dev/null | while read -r line; do
      if [[ "$line" == *"$PROJECT"* ]]; then
        local pid="${line%% *}"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
          kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
          sleep 0.2
          kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
          stopped=1
        fi
      fi
    done
  fi
  if [[ "$stopped" -eq 0 ]]; then
    echo -e "  ${DIM}   Dev server zaten kapalı.${RST}"
  fi
}

kill_tunnel_and_server() {
  if tunnel_running; then
    kill_tunnel
  else
    echo -e "  ${YEL}   Aktif tünel servisi yok.${RST}"
    pkill -f "cloudflared tunnel --url" 2>/dev/null || true
    killall cloudflared 2>/dev/null || true
    rm -f "$PID_FILE" "$URL_FILE"
  fi
  kill_dev_server
}

kill_all() {
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      kill -TERM "-$TPID" 2>/dev/null || kill -TERM "$TPID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-$TPID" 2>/dev/null || kill -KILL "$TPID" 2>/dev/null || true
      echo -e "  ${GRN}   Tünel servisi durduruldu - PID ${TPID}.${RST}"
    else
      echo -e "  ${DIM}   PID ${TPID} zaten çalışmıyor.${RST}"
    fi
  else
    echo -e "  ${YEL}   Tanımlı çalışan tünel servisi yok.${RST}"
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  kill_dev_server
  rm -f "$PID_FILE" "$URL_FILE" "${TMPDIR:-/tmp}/duendee-whatsapp-qr.png"
}

# Quiet cleanup for EXIT/INT/TERM/HUP (and the tunnel-watcher as backup)
CLEANING_UP=0
cleanup_quiet() {
  if [[ "$CLEANING_UP" == "1" ]]; then
    return 0
  fi
  CLEANING_UP=1
  DT_WA_TIMEOUT_MS=20000 retract_tunnel_whatsapp || true
  read_pid
  if [[ -n "${TPID:-}" ]] && pid_alive "$TPID"; then
    kill -TERM "-$TPID" 2>/dev/null || kill -TERM "$TPID" 2>/dev/null || true
    kill -KILL "-$TPID" 2>/dev/null || kill -KILL "$TPID" 2>/dev/null || true
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  local spid=""
  if [[ -f "$SERVER_PID" ]]; then
    spid="$(tr -d '[:space:]' < "$SERVER_PID" || true)"
  fi
  if [[ -n "$spid" ]]; then
    kill -TERM "-$spid" 2>/dev/null || kill -TERM "$spid" 2>/dev/null || true
    kill -KILL "-$spid" 2>/dev/null || kill -KILL "$spid" 2>/dev/null || true
    rm -f "$SERVER_PID"
  fi
  if [[ -n "${PROJECT:-}" ]]; then
    pgrep -af "npm run dev" 2>/dev/null | while read -r line; do
      if [[ "$line" == *"$PROJECT"* ]]; then
        local pid="${line%% *}"
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
      fi
    done
  fi
  rm -f "$PID_FILE" "$URL_FILE" "${TMPDIR:-/tmp}/duendee-whatsapp-qr.png" 2>/dev/null || true
}

wait_key() {
  if [[ -n "$AUTO" ]]; then
    return 0
  fi
  echo
  read -r -p "Devam etmek için Enter..." _
}

show_menu() {
  clear
  autostate
  # FIGlet "ANSI Shadow" — same layered block style as Claude Code
  echo
  echo -e "${SALMON}${BOLD}  ██████╗ ██╗   ██╗███████╗███╗   ██╗██████╗ ███████╗███████╗${RST}"
  echo -e "${SALMON}${BOLD}  ██╔══██╗██║   ██║██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝${RST}"
  echo -e "${SALMON}${BOLD}  ██║  ██║██║   ██║█████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ${RST}"
  echo -e "${SALMON}${BOLD}  ██║  ██║██║   ██║██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ${RST}"
  echo -e "${SALMON}${BOLD}  ██████╔╝╚██████╔╝███████╗██║ ╚████║██████╔╝███████╗███████╗${RST}"
  echo -e "${SALMON}${BOLD}  ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚══════╝${RST}"
  echo
  echo -e "${DIM}   ───────────────────────────────────────────────────────────${RST}"
  echo -e "${SKY}${BOLD}          D U E N D E E   T U N N E L   T O O L${RST}"
  echo -e "${DIM}   ───────────────────────────────────────────────────────────${RST}"
  echo
  echo -e "  ${YEL}${BOLD}[1]${RST}  ${SKY}Tünel Servisi Başlat${RST}"
  echo -e "  ${YEL}${BOLD}[2]${RST}  ${SKY}Servis Durumunu Kontrol Et${RST}"
  echo -e "  ${YEL}${BOLD}[3]${RST}  ${SKY}Yayın Linkini Kopyala${RST}"
  echo -e "  ${YEL}${BOLD}[4]${RST}  ${SKY}Tünel Servisini İptal Et${RST}"
  echo -e "  ${YEL}${BOLD}[5]${RST}  ${SKY}Tüm Terminalleri Kapat ve Çık${RST}"
  case "${AUTOMODE}" in
    tool) echo -e "  ${YEL}${BOLD}[6]${RST}  ${SKY}Cihaz Açılışında Otomatik Başlat${RST}  ${GRN}[TOOL]${RST}" ;;
    tunnel) echo -e "  ${YEL}${BOLD}[6]${RST}  ${SKY}Cihaz Açılışında Otomatik Başlat${RST}  ${GRN}[TOOL+TÜNEL]${RST}" ;;
    *) echo -e "  ${YEL}${BOLD}[6]${RST}  ${SKY}Cihaz Açılışında Otomatik Başlat${RST}  ${DIM}[KAPALI]${RST}" ;;
  esac
  echo -e "  ${YEL}${BOLD}[7]${RST}  ${SKY}Aracı Cihazdan Kaldır${RST}"
  echo
  echo -e "${DIM}      Kapatmak için pencereyi kapatın, [Ctrl]+[C] ya da [5]${RST}"
  echo
  printf "%b" "${CYN}   Seçim [1-7]: ${RST}"
}

do_start() {
  clear
  echo
  echo -e "${CYN}   --- Tünel servisi başlatılıyor ---${RST}"
  echo

  if ! find_cloudflared; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} cloudflared bulunamadı."
    wait_key
    return
  fi
  echo -e "  ${CYN}[1/4]${RST} cloudflared: $CF"

  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Servis zaten çalışıyor. Önce [4] ile iptal edin."
      wait_key
      return
    fi
    rm -f "$PID_FILE" "$URL_FILE"
  fi

  if [[ -f "$SERVER_PID" ]]; then
    local spid
    spid="$(tr -d '[:space:]' < "$SERVER_PID" || true)"
    if [[ -n "$spid" ]] && ! pid_alive "$spid"; then
      rm -f "$SERVER_PID"
    fi
  fi

  if port_listening "$PORT"; then
    echo -e "  ${CYN}[2/4]${RST} Dev server ${PORT} portunda hazır."
  else
    echo -e "  ${CYN}[2/4]${RST} Dev server başlatılıyor..."
    if [[ ! -d "${PROJECT}/node_modules" ]]; then
      echo -e "  ${DIM}   node_modules yok, npm install çalıştırılıyor...${RST}"
      (cd "$PROJECT" && npm install) || {
        echo -e "  ${RED}${BOLD}   [HATA]${RST} npm install başarısız."
        wait_key
        return
      }
    fi
    (
      cd "$PROJECT" || exit 1
      setsid npm run dev >"${STATE}/server.out.log" 2>&1 &
      echo $! >"$SERVER_PID"
    )
    local tries=0
    while true; do
      tries=$((tries + 1))
      if port_listening "$PORT"; then
        break
      fi
      if (( tries >= 80 )); then
        echo -e "  ${RED}${BOLD}[HATA]${RST} Dev server ${PORT} portunda açılamadı."
        echo -e "  ${DIM}   npm run dev çıktısını ayrı bir terminalde deneyin.${RST}"
        wait_key
        return
      fi
      sleep 0.25
    done
    echo -e "  ${CYN}[2/4]${RST} Dev server http://127.0.0.1:${PORT} hazır."
  fi

  echo -e "  ${CYN}[3/4]${RST} Cloudflare tünel başlatılıyor..."
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -f "$URL_FILE" "$LOG" "$OUT_LOG"
  URL=""
  TUNNEL_URL=""
  PREV=""
  # 127.0.0.1 + IPv4 edge avoids localhost/IPv6 happy-eyeballs delay
  local target="http://127.0.0.1:${PORT}"
  setsid "$CF" tunnel --url "$target" --no-autoupdate --protocol http2 --edge-ip-version 4 --retries 3 >"$OUT_LOG" 2>"$LOG" &
  echo $! >"$PID_FILE"
  read_pid
  if [[ -z "${TPID:-}" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel başlatılamadı. Log: $LOG"
    wait_key
    return
  fi
  sleep 0.3
  if ! pid_alive "$TPID"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel açılır açılmaz çıktı. Son log:"
    logtail
    rm -f "$PID_FILE"
    wait_key
    return
  fi

  echo -e "  ${CYN}[4/4]${RST} Yayın linki bekleniyor..."
  URL=""
  local tries=0
  while true; do
    refresh_url
    [[ -n "${URL:-}" ]] && break
    tries=$((tries + 1))
    if (( tries % 20 == 0 )); then
      echo -e "  ${DIM}   ... $((tries / 4)) saniye beklendi${RST}"
    fi
    if ! pid_alive "$TPID"; then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel çıktı, link alınamadı. Son log:"
      logtail
      rm -f "$PID_FILE" "$URL_FILE"
      wait_key
      return
    fi
    if (( tries >= 180 )); then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Yayın linki alınamadı - süre doldu. Son log:"
      logtail
      rm -f "$PID_FILE"
      wait_key
      return
    fi
    sleep 0.25
  done

  if ! port_listening "$PORT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Dev server origin ${PORT} portunda yanıt vermiyor."
    logtail
    rm -f "$PID_FILE" "$URL_FILE"
    wait_key
    return
  fi

  refresh_url
  tries=0
  while true; do
    local pub
    pub="$(http_code "${URL}" 3)"
    pub="${pub:-000}"
    if (( pub >= 200 && pub <= 399 )); then
      echo -e "  ${GRN}   Yayın adresi erişilebilir, kod: ${pub} - yayın hazır.${RST}"
      break
    fi
    tries=$((tries + 1))
    if (( tries >= 2 )); then
      echo -e "  ${YEL}   Uyarı: halka açık adres henüz doğrulanamadı, son kod: ${pub}.${RST}"
      echo -e "  ${DIM}   Cloudflare yönlendirmesi birkaç saniye içinde hazır olur.${RST}"
      break
    fi
    sleep 0.4
  done

  refresh_url
  echo
  echo -e "${GRN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║      YAYIN HAZIR - Diğer cihazlar bağlanabilir!      ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${RST}"
  echo
  logtail
  echo
  refresh_url
  if [[ -n "${URL:-}" ]]; then
    if copy_clipboard "$URL"; then
      echo -e "${GRN}   Link panoya kopyalandı.${RST}  Gerekirse [3] ile yeniden kopyalayın."
    else
      echo -e "${YEL}   Panoya kopyalanamadı (xclip/wl-copy yok). Link:${RST}"
    fi
    echo -e "${BLUE}${BOLD}     ${URL}${RST}"
    echo
    echo "  Varsayılan tarayıcıda açılıyor..."
    open_url "$URL"
    send_tunnel_whatsapp "$URL"
  fi
  echo
  wait_key
}

do_status() {
  clear
  echo
  echo -e "${CYN}   --- Servis Durumu ---${RST}"
  echo
  if port_listening "$PORT"; then
    echo -e "  Dev Server ........ ${GRN}ÇALIŞIYOR${RST}  -  http://localhost:${PORT}"
  else
    echo -e "  Dev Server ........ ${RED}KAPALI${RST}"
  fi
  read_pid
  if [[ -n "${TPID:-}" ]] && pid_alive "$TPID"; then
    echo -e "  Tünel Servisi ..... ${GRN}ÇALIŞIYOR${RST}  -  PID ${TPID}"
    refresh_url
    [[ -n "${URL:-}" ]] && echo -e "  Yayın Linki ......... ${BLUE}${BOLD}${URL}${RST}"
  else
    echo -e "  Tünel Servisi ..... ${RED}KAPALI${RST}"
  fi
  if [[ -f "$LOG" ]]; then
    logtail brief
  fi
  echo
  wait_key
}

do_copylink() {
  clear
  echo
  read_pid
  if [[ -z "${TPID:-}" ]] || ! pid_alive "$TPID"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Aktif yayın linki yok."
    echo -e "  ${DIM}   Önce [1] ile tünel servisini başlatın.${RST}"
    echo
    wait_key
    return
  fi
  refresh_url
  if [[ -z "${URL:-}" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Aktif yayın linki yok."
    echo -e "  ${DIM}   Önce [1] ile tünel servisini başlatın.${RST}"
    echo
    wait_key
    return
  fi
  if copy_clipboard "$URL"; then
    echo -e "${GRN}   Yayın linki panoya kopyalandı:${RST}"
  else
    echo -e "${YEL}   Panoya kopyalanamadı (xclip/wl-copy yok):${RST}"
  fi
  echo -e "${BLUE}${BOLD}     ${URL}${RST}"
  echo
  wait_key
}

do_cancel() {
  clear
  echo
  echo -e "${CYN}   --- Tünel servisini iptal et ---${RST}"
  echo
  local had_tunnel=0
  local had_server=0
  tunnel_running && had_tunnel=1
  if [[ -f "$SERVER_PID" ]]; then
    local spid
    spid="$(tr -d '[:space:]' < "$SERVER_PID" || true)"
    if [[ -n "$spid" ]] && pid_alive "$spid"; then
      had_server=1
    fi
  fi
  if [[ "$had_tunnel" -eq 0 && "$had_server" -eq 0 ]]; then
    echo -e "  ${YEL}   Aktif tünel servisi yok.${RST}"
    echo -e "  ${DIM}   İptal edilecek bir şey yok. Başlatmak için menüden [1] kullanın.${RST}"
    echo
    wait_key
    return 0
  fi
  kill_tunnel_and_server
  URL=""
  TUNNEL_URL=""
  PREV=""
  retract_tunnel_whatsapp
  echo -e "  ${GRN}   Tünel ve dev server iptal edildi. Yeni tünel otomatik başlatılmadı.${RST}"
  echo
  wait_key
}

write_autostart_unit() {
  local arg="${1:-}"
  mkdir -p "$AUTO_UNIT_DIR"
  cat >"$AUTO_UNIT" <<EOF
[Unit]
Description=Duendee Tunnel Tool
After=default.target

[Service]
Type=simple
ExecStart=${HOME}/.local/bin/duendee-tunnel ${arg}
WorkingDirectory=${HOME}
Restart=no

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user enable duendee-tunnel-tool.service >/dev/null 2>&1; then
    loginctl enable-linger "$USER" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

register_stable_launch() {
  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/duendee-tunnel"
  local shim="${HOME}/.local/bin/duendee-tunnel"
  local src="${OS_DIR}/stable-launch.sh"
  mkdir -p "$cfg_dir" "${HOME}/.local/bin"
  printf '%s\n' "$ROOT" >"${cfg_dir}/root"
  if [[ -f "$src" ]]; then
    cp "$src" "$shim"
    chmod +x "$shim" "$src" 2>/dev/null || true
  fi
  if [[ -f "$AUTO_UNIT" ]]; then
    local arg=""
    if grep -q 'boot-tunnel' "$AUTO_UNIT"; then
      arg="boot-tunnel"
    fi
    write_autostart_unit "$arg" || true
  fi
}

disable_autostart() {
  systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
  rm -f "$AUTO_UNIT"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

do_autostart() {
  local ans="" choices="TSX"
  clear
  echo
  echo -e "${CYN}   --- Cihaz Açılışında Otomatik Başlat ---${RST}"
  echo
  autostate
  case "$AUTOMODE" in
    tool)
      echo -e "  ${DIM}   Durum:${RST} ${GRN}${BOLD}[TOOL]${RST}"
      echo -e "  ${DIM}   Cihaz açıldığında yalnızca tool açılır. Tünel servisini [1] ile başlatırsın.${RST}"
      ;;
    tunnel)
      echo -e "  ${DIM}   Durum:${RST} ${GRN}${BOLD}[TOOL+TÜNEL]${RST}"
      echo -e "  ${DIM}   Cihaz açıldığında tool açılır ve tünel servisi kendiliğinden başlar.${RST}"
      ;;
    *)
      echo -e "  ${DIM}   Durum:${RST} ${RED}${BOLD}[KAPALI]${RST}"
      echo -e "  ${DIM}   Cihaz açıldığında tool açılmıyor.${RST}"
      ;;
  esac
  echo
  echo -e "  ${YEL}${BOLD}[T]${RST}  ${SKY}Yalnızca tool'u otomatik başlat${RST}"
  echo -e "  ${YEL}${BOLD}[S]${RST}  ${SKY}Tool'u ve tünel servisini otomatik başlat${RST}"
  if [[ "$AUTOMODE" != "off" ]]; then
    echo -e "  ${YEL}${BOLD}[K]${RST}  ${SKY}Otomatik başlatmayı kapat${RST}"
    choices="TSKX"
  fi
  echo -e "  ${YEL}${BOLD}[X]${RST}  ${SKY}Geri dön${RST}"
  echo
  printf "%b" "${CYN}   Seçim: ${RST}"
  read -r -n 1 ans
  echo
  case "${ans^^}" in
    T)
      if [[ "$AUTOMODE" == "tool" ]]; then
        echo -e "  ${YEL}   Bu ayar zaten seçili.${RST}"
      elif write_autostart_unit ""; then
        echo -e "  ${GRN}   Yalnızca tool otomatik başlayacak.${RST}"
        echo -e "  ${DIM}   Kayıt: ${AUTO_UNIT}${RST}"
      else
        echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kaydedilemedi."
        echo -e "  ${DIM}   systemd --user kullanılabilir olmalı.${RST}"
      fi
      ;;
    S)
      if [[ "$AUTOMODE" == "tunnel" ]]; then
        echo -e "  ${YEL}   Bu ayar zaten seçili.${RST}"
      elif write_autostart_unit "boot-tunnel"; then
        echo -e "  ${GRN}   Tool ve tünel servisi otomatik başlayacak.${RST}"
        echo -e "  ${DIM}   Kayıt: ${AUTO_UNIT}${RST}"
      else
        echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kaydedilemedi."
        echo -e "  ${DIM}   systemd --user kullanılabilir olmalı.${RST}"
      fi
      ;;
    K)
      [[ "$AUTOMODE" == "off" ]] && return 0
      disable_autostart
      autostate
      echo
      if [[ "$AUTOMODE" == "off" ]]; then
        echo -e "  ${GRN}   Otomatik başlatma kapatıldı.${RST}"
      else
        echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kapatılamadı, kayıt duruyor."
      fi
      ;;
    *) return 0 ;;
  esac
  echo
  wait_key
}

is_uninstall_arg() {
  case "${1:-}" in
    7|uninstall|kaldir|kaldır|remove) return 0 ;;
    *) return 1 ;;
  esac
}

normalized_dir() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  else
    printf '%s\n' "$p"
  fi
}

install_dir_default() {
  if [[ -n "${DT_INSTALL_DIR:-}" ]]; then
    printf '%s\n' "$DT_INSTALL_DIR"
    return 0
  fi
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/duendee-tunnel-tool"
}

strip_path_marker() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk '
    $0 == "# Duendee Tunnel Tool PATH" { skip=1; next }
    skip == 1 && $0 ~ /^export PATH=/ { skip=0; next }
    { skip=0; print }
  ' "$rc" >"$tmp"
  mv "$tmp" "$rc"
}

remove_shim_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -q 'duendee-tunnel-tool.sh' "$f" 2>/dev/null; then
    rm -f "$f" 2>/dev/null || sudo rm -f "$f" 2>/dev/null || true
  fi
}

pkg_installed() {
  local name="$1"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -s "$name" >/dev/null 2>&1
    return $?
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q "$name" >/dev/null 2>&1
    return $?
  fi
  if command -v pacman >/dev/null 2>&1; then
    pacman -Qi "$name" >/dev/null 2>&1
    return $?
  fi
  return 1
}

file_owned_by_package() {
  local f="$1"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -S "$f" >/dev/null 2>&1 && return 0
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -qf "$f" >/dev/null 2>&1 && return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    pacman -Qo "$f" >/dev/null 2>&1 && return 0
  fi
  return 1
}

remove_unmanaged_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || return 0
  local path
  path="$(command -v "$bin")"
  [[ "$(basename "$path")" == "$bin" ]] || return 0
  if file_owned_by_package "$path"; then
    return 0
  fi
  case "$path" in
    "$HOME"/*|/usr/local/bin/*|/usr/bin/*)
      rm -f "$path" 2>/dev/null || sudo rm -f "$path" 2>/dev/null || true
      ;;
  esac
}

remove_dependencies() {
  local pkgs=()
  local name
  for name in nodejs npm cloudflared; do
    if pkg_installed "$name"; then
      pkgs+=("$name")
    fi
  done
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    echo -e "  ${DIM}   Paketler kaldırılıyor: ${pkgs[*]}${RST}"
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get remove -y "${pkgs[@]}" || echo -e "  ${YEL}   apt kaldırma tamamlanamadı.${RST}"
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf remove -y "${pkgs[@]}" || echo -e "  ${YEL}   dnf kaldırma tamamlanamadı.${RST}"
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -Rns --noconfirm "${pkgs[@]}" || echo -e "  ${YEL}   pacman kaldırma tamamlanamadı.${RST}"
    else
      echo -e "  ${YEL}   Paket yöneticisi bulunamadı. Paketler duruyor: ${pkgs[*]}${RST}"
    fi
  fi
  remove_unmanaged_bin cloudflared
  remove_unmanaged_bin node
  remove_unmanaged_bin npm
  remove_unmanaged_bin npx
  if command -v node >/dev/null 2>&1; then
    echo -e "  ${YEL}   Node.js hâlâ duruyor: $(command -v node)${RST}"
  else
    echo -e "  ${GRN}   Node.js bu oturumda artık yok.${RST}"
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    echo -e "  ${YEL}   cloudflared hâlâ duruyor: $(command -v cloudflared)${RST}"
  else
    echo -e "  ${GRN}   cloudflared bu oturumda artık yok.${RST}"
  fi
}

print_uninstall_plan() {
  local mode="$1"
  local install root_full seen="" dir
  install="$(install_dir_default)"
  root_full="$(normalized_dir "$ROOT")"
  for dir in "$install" "$root_full"; do
    [[ -n "$dir" ]] || continue
    case " $seen " in
      *" $dir "*) continue ;;
    esac
    seen="$seen $dir"
    if [[ -d "$dir" ]]; then
      echo -e "  ${DIM}   - Tool klasörü: ${dir}${RST}"
    fi
  done
  echo -e "  ${DIM}   - Komut: ${HOME}/.local/bin/duendee-tunnel${RST}"
  if [[ -e /usr/local/bin/duendee-tunnel ]]; then
    echo -e "  ${DIM}   - Komut: /usr/local/bin/duendee-tunnel${RST}"
  fi
  echo -e "  ${DIM}   - PATH satırı (~/.bashrc, ~/.zshrc, ~/.profile, ~/.bash_profile)${RST}"
  echo -e "  ${DIM}   - Otomatik başlatma: ${AUTO_UNIT}${RST}"
  if [[ -f "$AUTO_DESKTOP" ]]; then
    echo -e "  ${DIM}   - Otomatik başlatma: ${AUTO_DESKTOP}${RST}"
  fi
  if [[ "$mode" == "2" ]]; then
    echo -e "  ${DIM}   - Node.js (bu cihazdaki kurulum; diğer programlar da etkilenir)${RST}"
    echo -e "  ${DIM}   - cloudflared (bu cihazdaki kurulum)${RST}"
  fi
}

do_uninstall() {
  local mode="${1:-}"
  local ans=""
  clear
  echo
  echo -e "${CYN}   --- Aracı Kaldır ---${RST}"
  echo
  if [[ "$mode" != "1" && "$mode" != "2" ]]; then
    echo -e "  ${YEL}${BOLD}[1]${RST}  ${SKY}Yalnızca Duendee Tunnel Tool${RST}"
    echo -e "  ${DIM}      Kurulum, komut, PATH ve otomatik başlatma silinir.${RST}"
    echo -e "  ${YEL}${BOLD}[2]${RST}  ${SKY}Tool ile birlikte Node.js ve cloudflared${RST}"
    echo -e "  ${DIM}      [1] ile aynı, artı bu cihazdaki Node.js ve cloudflared.${RST}"
    echo -e "  ${YEL}${BOLD}[X]${RST}  ${SKY}Vazgeç${RST}"
    echo
    printf "%b" "${CYN}   Seçim [1/2/X]: ${RST}"
    read -r -n 1 ans
    echo
    case "${ans^^}" in
      1|2) mode="$ans" ;;
      *) return 0 ;;
    esac
  fi

  echo
  echo -e "  ${RED}${BOLD}Emin misiniz?${RST} Bu işlem geri alınamaz."
  echo
  print_uninstall_plan "$mode"
  echo
  printf "%b" "${CYN}   [E] Evet, kaldır    [H] Hayır: ${RST}"
  read -r -n 1 ans
  echo
  case "${ans^^}" in
    E) ;;
    *)
      echo
      echo -e "  ${YEL}   Kaldırma iptal edildi.${RST}"
      if [[ -z "${UNINSTALL_CLI:-}" ]]; then
        wait_key
      fi
      return 0
      ;;
  esac

  echo
  CLEANING_UP=1
  kill_all || true
  systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
  rm -f "$AUTO_UNIT" "$AUTO_DESKTOP" 2>/dev/null || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true

  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    strip_path_marker "$rc"
  done
  remove_shim_file "${HOME}/.local/bin/duendee-tunnel"
  remove_shim_file /usr/local/bin/duendee-tunnel
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/duendee-tunnel" 2>/dev/null || true

  if [[ "$mode" == "2" ]]; then
    remove_dependencies
  fi

  local install root_full seen="" dir tries
  install="$(install_dir_default)"
  root_full="$(normalized_dir "$ROOT")"
  cd /tmp 2>/dev/null || cd "$HOME" || true
  for dir in "$install" "$root_full"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    case " $seen " in
      *" $dir "*) continue ;;
    esac
    seen="$seen $dir"
    tries=0
    while [[ -d "$dir" && "$tries" -lt 20 ]]; do
      rm -rf "$dir" 2>/dev/null || sudo rm -rf "$dir" 2>/dev/null || true
      [[ -d "$dir" ]] || break
      tries=$((tries + 1))
      sleep 0.5
    done
    if [[ -d "$dir" ]]; then
      echo -e "  ${YEL}   Silinemedi: ${dir}${RST}"
    else
      echo -e "  ${GRN}   Silindi: ${dir}${RST}"
    fi
  done
  echo
  echo -e "  ${GRN}   Kaldırma tamam.${RST}"
  echo
  exit 0
}

do_shutdown() {
  clear
  echo
  echo -e "${CYN}   --- Tüm terminaller kapatılıyor ---${RST}"
  retract_tunnel_whatsapp
  kill_all
  CLEANING_UP=1
  echo -e "${GRN}   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...${RST}"
  echo
  exit 0
}

# ---- entry ----
if is_uninstall_arg "${1:-}"; then
  UNINSTALL_CLI=1
  do_uninstall "${2:-}"
  exit 0
fi

load_config
trap cleanup_quiet EXIT INT TERM HUP
register_stable_launch || true
start_watcher

if [[ "${1:-}" == "boot-tunnel" ]]; then
  do_start
elif [[ "${1:-}" != "" ]]; then
  AUTO=1
  case "$1" in
    1) do_start; exit 0 ;;
    2) do_status; exit 0 ;;
    3) do_copylink; exit 0 ;;
    4) do_cancel; exit 0 ;;
    5) do_shutdown ;;
    6) do_autostart; exit 0 ;;
  esac
fi

while true; do
  show_menu
  read -r -n 1 choice
  echo
  case "$choice" in
    1) do_start ;;
    2) do_status ;;
    3) do_copylink ;;
    4) do_cancel ;;
    5) do_shutdown ;;
    6) do_autostart ;;
    7) do_uninstall ;;
    *) ;;
  esac
done
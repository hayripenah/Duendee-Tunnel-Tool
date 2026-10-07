#!/usr/bin/env bash
# Duendee Tunnel Tool (Linux)
# Mirrors the Windows .bat menu: start/status/copy/cancel/shutdown/autostart.
set -u
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${TOOL}/.tunnelstate"
PID_FILE="${STATE}/tunnel.pid"
URL_FILE="${STATE}/tunnel.url"
LOG="${STATE}/tunnel.log"
OUT_LOG="${STATE}/tunnel.out.log"
SERVER_PID="${STATE}/server.pid"
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
DEEP=$'\033[38;2;30;64;175m'
SKY=$'\033[38;2;147;197;253m'

mkdir -p "$STATE"

die() {
  echo -e "  ${RED}${BOLD}[HATA]${RST} $*"
  exit 1
}

load_config() {
  local cfg="${TOOL}/config.json"
  if [[ ! -f "$cfg" ]]; then
    die "config.json bulunamadı. Önce config.example.json dosyasını config.json olarak kopyalayıp projectPath ayarlayın."
  fi
  if command -v python3 >/dev/null 2>&1; then
    PROJECT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("projectPath",""))' "$cfg")"
    PORT="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1],encoding="utf-8")); print(c.get("port") or 8080)' "$cfg")"
  elif command -v node >/dev/null 2>&1; then
    PROJECT="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.projectPath||""))' "$cfg")"
    PORT="$(node -e 'const c=require(process.argv[1]); process.stdout.write(String(c.port||8080))' "$cfg")"
  else
    die "config.json okumak için python3 veya node gerekli."
  fi
  [[ -n "${PROJECT:-}" ]] || die "config.json içinde projectPath tanımlı değil."
  [[ -d "$PROJECT" ]] || die "projectPath bulunamadı: $PROJECT"
  PORT="${PORT:-8080}"
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
  bash "${TOOL}/scripts/extract-tunnel-url.sh" "$LOG" "$OUT_LOG" "$URL_FILE" >/dev/null 2>&1 || true
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

logtail() {
  echo -e "  ${DIM}   Son log:${RST}"
  if [[ ! -f "$LOG" ]]; then
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
  AUTOEN=0
  if systemctl --user is-enabled duendee-tunnel-tool.service >/dev/null 2>&1; then
    AUTOEN=1
  elif [[ -f "$AUTO_UNIT" ]]; then
    # unit present but maybe not enabled
    if systemctl --user is-enabled duendee-tunnel-tool.service >/dev/null 2>&1; then
      AUTOEN=1
    fi
  fi
}

start_watcher() {
  local tool_pid="$$"
  nohup bash "${TOOL}/scripts/tunnel-watcher.sh" "$tool_pid" "$PROJECT" "$TOOL" \
    >/dev/null 2>&1 &
}

kill_tunnel() {
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      kill -TERM "$TPID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "$TPID" 2>/dev/null || true
      echo -e "  ${GRN}   Eski tünel durduruldu - PID ${TPID}.${RST}"
    fi
  else
    echo -e "  ${DIM}   Aktif tünel yok, yeni link başlatılacak.${RST}"
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -f "$PID_FILE" "$URL_FILE"
}

kill_all() {
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      kill -TERM "$TPID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "$TPID" 2>/dev/null || true
      echo -e "  ${GRN}   Tünel servisi durduruldu - PID ${TPID}.${RST}"
    else
      echo -e "  ${DIM}   PID ${TPID} zaten çalışmıyor.${RST}"
    fi
  else
    echo -e "  ${YEL}   Tanımlı çalışan tünel servisi yok.${RST}"
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true

  local spid=""
  if [[ -f "$SERVER_PID" ]]; then
    spid="$(tr -d '[:space:]' < "$SERVER_PID" || true)"
  fi
  if [[ -n "$spid" ]]; then
    if pid_alive "$spid"; then
      # kill process group if possible
      kill -TERM "-$spid" 2>/dev/null || kill -TERM "$spid" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-$spid" 2>/dev/null || kill -KILL "$spid" 2>/dev/null || true
      echo -e "  ${GRN}   Dev server penceresi kapatıldı - PID ${spid}.${RST}"
    else
      echo -e "  ${DIM}   Dev server zaten kapalı.${RST}"
    fi
    rm -f "$SERVER_PID"
  fi
  rm -f "$PID_FILE" "$URL_FILE" "${TMPDIR:-/tmp}/duendee-whatsapp-qr.png"
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
  echo
  echo -e "${BLUE}${BOLD}    █████ █   █ █████ █   █ █████ █████ █████${RST}"
  echo -e "${DEEP}      █████ █   █ █████ █   █ █████ █████ █████${RST}"
  echo -e "${BLUE}${BOLD}    █   █ █   █ █     ██  █ █   █ █     █${RST}"
  echo -e "${DEEP}      █   █ █   █ █     ██  █ █   █ █     █${RST}"
  echo -e "${BLUE}${BOLD}    █   █ █   █ █     █ █ █ █   █ █     █${RST}"
  echo -e "${DEEP}      █   █ █   █ █     █ █ █ █   █ █     █${RST}"
  echo -e "${BLUE}${BOLD}    █   █ █   █ █████ █  ██ █   █ █████ █████${RST}"
  echo -e "${DEEP}      █   █ █   █ █████ █  ██ █   █ █████ █████${RST}"
  echo -e "${BLUE}${BOLD}    █   █ █   █ █     █   █ █   █ █     █${RST}"
  echo -e "${DEEP}      █   █ █   █ █     █   █ █   █ █     █${RST}"
  echo -e "${BLUE}${BOLD}    █   █ █   █ █     █   █ █   █ █     █${RST}"
  echo -e "${DEEP}      █   █ █   █ █     █   █ █   █ █     █${RST}"
  echo -e "${BLUE}${BOLD}    █████ █████ █████ █   █ █████ █████ █████${RST}"
  echo -e "${DEEP}      █████ █████ █████ █   █ █████ █████ █████${RST}"
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
  if [[ "${AUTOEN}" == "1" ]]; then
    echo -e "  ${YEL}${BOLD}[6]${RST}  ${SKY}Cihaz Açılışında Otomatik Başlat${RST}  ${GRN}[AÇIK]${RST}"
  else
    echo -e "  ${YEL}${BOLD}[6]${RST}  ${SKY}Cihaz Açılışında Otomatik Başlat${RST}  ${DIM}[KAPALI]${RST}"
  fi
  echo
  echo -e "${DIM}      Kapatmak için pencereyi kapatın, [Ctrl]+[C] ya da [5]${RST}"
  echo
  printf "%b" "${CYN}   Seçim [1-6]: ${RST}"
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
      if (( tries >= 20 )); then
        echo -e "  ${RED}${BOLD}[HATA]${RST} Dev server ${PORT} portunda açılamadı."
        echo -e "  ${DIM}   npm run dev çıktısını ayrı bir terminalde deneyin.${RST}"
        wait_key
        return
      fi
      sleep 1
    done
    echo -e "  ${CYN}[2/4]${RST} Dev server http://localhost:${PORT} hazır."
  fi

  echo -e "  ${CYN}[3/4]${RST} Cloudflare tünel başlatılıyor..."
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -f "$URL_FILE" "$LOG" "$OUT_LOG"
  URL=""
  TUNNEL_URL=""
  PREV=""
  local target="http://localhost:${PORT}"
  setsid "$CF" tunnel --url "$target" --no-autoupdate >"$OUT_LOG" 2>"$LOG" &
  echo $! >"$PID_FILE"
  read_pid
  if [[ -z "${TPID:-}" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel başlatılamadı. Log: $LOG"
    wait_key
    return
  fi
  sleep 1
  if ! pid_alive "$TPID"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel açılır açılmaz çıktı. Son log:"
    logtail
    rm -f "$PID_FILE"
    wait_key
    return
  fi

  echo -e "  ${CYN}[4/4]${RST} Yayın linki bekleniyor - 60 sn'ye kadar..."
  URL=""
  local tries=0
  while true; do
    refresh_url
    [[ -n "${URL:-}" ]] && break
    tries=$((tries + 1))
    if (( tries % 5 == 0 )); then
      echo -e "  ${DIM}   ... ${tries} saniye beklendi${RST}"
    fi
    if ! pid_alive "$TPID"; then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel çıktı, link alınamadı. Son log:"
      logtail
      rm -f "$PID_FILE" "$URL_FILE"
      wait_key
      return
    fi
    if (( tries >= 60 )); then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Yayın linki alınamadı - 60 sn doldu. Son log:"
      logtail
      rm -f "$PID_FILE"
      wait_key
      return
    fi
    sleep 1
  done

  echo -e "  ${DIM}   Link alındı, origin sağlığı doğrulanıyor...${RST}"
  tries=0
  while true; do
    local orig
    orig="$(http_code "http://localhost:${PORT}" 4)"
    orig="${orig:-000}"
    if (( orig >= 200 && orig <= 399 )); then
      echo -e "  ${GRN}   Origin kontrolü başarılı, kod: ${orig}.${RST}"
      break
    fi
    tries=$((tries + 1))
    if ! pid_alive "$TPID"; then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel bağlantı sırasında çıktı."
      logtail
      rm -f "$PID_FILE" "$URL_FILE"
      wait_key
      return
    fi
    if (( tries >= 15 )); then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Dev server origin ${PORT} portunda yanıt vermiyor, son kod: ${orig}."
      echo -e "  ${DIM}   000 = bağlantı kurulamadı, 4xx/5xx = sunucu hata kodu; npm run dev penceresini kontrol edin.${RST}"
      logtail
      rm -f "$PID_FILE" "$URL_FILE"
      wait_key
      return
    fi
    sleep 1
  done

  refresh_url
  tries=0
  while true; do
    local pub
    pub="$(http_code "${URL}" 6)"
    pub="${pub:-000}"
    if (( pub >= 200 && pub <= 399 )); then
      echo -e "  ${GRN}   Yayın adresi erişilebilir, kod: ${pub} - yayın hazır.${RST}"
      break
    fi
    tries=$((tries + 1))
    if (( tries >= 3 )); then
      echo -e "  ${YEL}   Uyarı: halka açık adres henüz doğrulanamadı, son kod: ${pub}.${RST}"
      echo -e "  ${DIM}   000 = Cloudflare henüz yönlendirmiyor; birkaç saniye içinde erişilebilir olur.${RST}"
      break
    fi
    sleep 1
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
    echo "  WhatsApp'a link gönderiliyor..."
    node "${TOOL}/scripts/send-whatsapp.js" "$URL_FILE" "+905315162429" || true
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
    logtail
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
  echo -e "${CYN}   --- Yeni tünel linki oluşturuluyor ---${RST}"
  echo
  kill_tunnel
  URL=""
  TUNNEL_URL=""
  PREV=""
  sleep 1
  do_start
}

do_autostart() {
  clear
  echo
  echo -e "${CYN}   --- Cihaz Açılışında Otomatik Başlat ---${RST}"
  echo
  autostate
  if [[ "$AUTOEN" == "1" ]]; then
    echo -e "  ${DIM}   Durum:${RST} ${YEL}${BOLD}[AÇIK]${RST}"
    echo -e "  ${DIM}   Cihaz açıldığında tool kendiliğinden açılır, servisi [1] ile elle başlatırsın.${RST}"
    echo
    printf "   Otomatik başlatmayı kapat  [K]   -   geri dön  [X]: "
    read -r -n 1 ans
    echo
    case "${ans^^}" in
      K)
        systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
        rm -f "$AUTO_UNIT"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        autostate
        echo
        if [[ "$AUTOEN" == "0" ]]; then
          echo -e "  ${GRN}   Otomatik başlatma kapatıldı.${RST}"
          echo -e "  ${DIM}   Bundan sonra cihaz açıldığında tool açılmayacak.${RST}"
        else
          echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kapatılamadı, kayıt duruyor."
        fi
        ;;
      *) return ;;
    esac
  else
    echo -e "  ${DIM}   Durum:${RST} ${RED}${BOLD}[KAPALI]${RST}"
    echo -e "  ${DIM}   Cihaz açıldığında tool açılmıyor.${RST}"
    echo
    printf "   Otomatik başlatmayı aç  [A]   -   geri dön  [X]: "
    read -r -n 1 ans
    echo
    case "${ans^^}" in
      A)
        mkdir -p "$AUTO_UNIT_DIR"
        cat >"$AUTO_UNIT" <<EOF
[Unit]
Description=Duendee Tunnel Tool
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash "${TOOL}/duendee-tunnel-tool.sh"
WorkingDirectory=${TOOL}
Restart=no

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        if systemctl --user enable duendee-tunnel-tool.service >/dev/null 2>&1; then
          # linger so user units can start at boot without login (best-effort)
          loginctl enable-linger "$USER" >/dev/null 2>&1 || true
        fi
        autostate
        echo
        if [[ "$AUTOEN" == "1" ]]; then
          echo -e "  ${GRN}   Otomatik başlatma açık.${RST}"
          echo -e "  ${DIM}   Bundan sonra cihaz açıldığında tool kendiliğinden açılacak. Servisi [1] ile başlatabilirsin.${RST}"
          echo -e "  ${DIM}   Kayıt: ${AUTO_UNIT}${RST}"
        else
          echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kaydedilemedi, kayıt oluşturulamadı."
          echo -e "  ${DIM}   systemd --user kullanılabilir olmalı.${RST}"
        fi
        ;;
      *) return ;;
    esac
  fi
  echo
  wait_key
}

do_shutdown() {
  clear
  echo
  echo -e "${CYN}   --- Tüm terminaller kapatılıyor ---${RST}"
  kill_all
  echo -e "${GRN}   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...${RST}"
  echo
  exit 0
}

# ---- entry ----
load_config
start_watcher

if [[ "${1:-}" != "" ]]; then
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
    *) ;;
  esac
done
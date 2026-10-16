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
# One hue per menu action. Detail stays dim. Red is only for errors.
C1=$'\033[96m'
C2=$'\033[38;2;96;165;250m'
C3=$'\033[38;2;125;211;252m'
C4=$'\033[38;2;251;146;60m'
C5=$'\033[38;2;167;139;250m'
C6=$'\033[38;2;251;113;133m'

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

public_git() {
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"
}

github_slug() {
  local repo="$1"
  repo="${repo%.git}"
  repo="${repo#https://github.com/}"
  repo="${repo#git@github.com:}"
  printf '%s' "$repo"
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
      echo -e "  ${YEL}   GitHub CLI bu mimaride kurulamadı: $(uname -m)${RST}" >&2
      return 1
      ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  echo "  GitHub CLI kuruluyor (tek sefer)..." >&2
  dest="${HOME}/.local/share/duendee-gh"
  tmp="$(mktemp)"
  if ! curl -fsSL -o "$tmp" "https://github.com/cli/cli/releases/download/v${ver}/${name}"; then
    rm -f "$tmp"
    echo -e "  ${YEL}   GitHub CLI indirilemedi.${RST}" >&2
    return 1
  fi
  mkdir -p "$dest" "${HOME}/.local/bin"
  tar -xzf "$tmp" -C "$dest" --strip-components=1
  rm -f "$tmp"
  ln -sfn "${dest}/bin/gh" "${HOME}/.local/bin/gh"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

git_with_gh() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 git -c 'credential.helper=!gh auth git-credential' "$@"
  else
    public_git "$@"
  fi
}

fetch_private_github() {
  local repo="$1"
  local target="$2"
  ensure_gh || return 1
  if ! gh auth status >/dev/null 2>&1; then
    echo "  Private repo. GitHub CLI girişi bir kez istenir; şifre repoya yazılmaz." >&2
    gh auth login --hostname github.com --git-protocol https --web || return 1
  fi
  GH_PROMPT_DISABLED=1 gh repo clone "$repo" "$target" -- --depth 1
}

fetch_public_github() {
  local url="$1"
  local target="$2"
  local repo tmp branch inner
  repo="$(github_slug "$url")"
  command -v curl >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  tmp="$(mktemp -d)"
  for branch in main master; do
    if curl -fsSL -o "${tmp}/src.tgz" "https://codeload.github.com/${repo}/tar.gz/refs/heads/${branch}"; then
      tar -xzf "${tmp}/src.tgz" -C "$tmp" || true
      inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -n1 || true)"
      if [[ -n "$inner" && -d "$inner" ]]; then
        mkdir -p "$(dirname "$target")"
        rm -rf "$target"
        mv "$inner" "$target"
        rm -rf "$tmp"
        return 0
      fi
    fi
  done
  rm -rf "$tmp"
  fetch_private_github "$repo" "$target"
}

restore_kept_duendee() {
  local path="$1" tmp="$2" item
  for item in .env .env.local node_modules; do
    if [[ -e "${tmp}/keep/${item}" ]]; then
      rm -rf "${path}/${item}"
      mv "${tmp}/keep/${item}" "${path}/${item}"
    fi
  done
}

refresh_duendee_snapshot() {
  local path="$1"
  local tmp stage item left
  tmp="$(mktemp -d)"
  stage="${tmp}/stage"
  if ! fetch_public_github "$DUENDEE_REPO_URL" "$stage"; then
    rm -rf "$tmp"
    echo -e "  ${YEL}   Duendee güncellenemedi.${RST}" >&2
    return 1
  fi
  mkdir -p "${tmp}/keep"
  for item in .env .env.local node_modules; do
    if [[ -e "${path}/${item}" ]]; then
      mv "${path}/${item}" "${tmp}/keep/${item}"
    fi
  done
  local failed=0 name dest base
  local -a stage_names=()
  find "$path" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} + || true
  shopt -s dotglob
  for name in "${stage}/"*; do
    [[ -e "$name" ]] || continue
    base="$(basename "$name")"
    stage_names+=("$base")
    dest="${path}/${base}"
    if [[ -e "$dest" ]]; then
      rm -rf "$dest" || true
    fi
    if [[ -e "$dest" ]]; then
      failed=1
      continue
    fi
    mv "$name" "$dest" || failed=1
  done
  shopt -u dotglob
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    base="$(basename "$name")"
    local known=0 staged
    for staged in "${stage_names[@]+"${stage_names[@]}"}"; do
      [[ "$staged" == "$base" ]] && known=1
    done
    [[ "$known" -eq 1 ]] || failed=1
  done < <(find "$path" -mindepth 1 -maxdepth 1 ! -name '.git' -print 2>/dev/null || true)
  restore_kept_duendee "$path" "$tmp"
  rm -rf "$tmp"
  if [[ "$failed" -eq 1 || ! -f "${path}/package.json" ]]; then
    echo -e "  ${YEL}   Duendee güncellenemedi.${RST}" >&2
    return 1
  fi
  echo -e "  ${DIM}   Repo güncel.${RST}" >&2
}

duendee_git_matches() {
  local path="$1" tip_rev="$2" head tip
  head="$(git_with_gh -C "$path" rev-parse HEAD 2>/dev/null || true)"
  tip="$(git_with_gh -C "$path" rev-parse "$tip_rev" 2>/dev/null || true)"
  [[ -n "$head" && "$head" == "$tip" ]]
}

fetch_duendee_ref() {
  local path="$1" remote="$2" branch="$3"
  git_with_gh -C "$path" fetch --depth 1 "$remote" "$branch" >/dev/null 2>&1 \
    || git_with_gh -C "$path" fetch "$remote" "$branch" >/dev/null 2>&1
}

reset_duendee_to() {
  local path="$1" rev="$2"
  git_with_gh -C "$path" reset --hard "$rev" >/dev/null 2>&1 \
    && duendee_git_matches "$path" "$rev"
}

update_duendee_from_git() {
  local path="$1" remote="$2" branch tip_rev
  for branch in main master; do
    fetch_duendee_ref "$path" "$remote" "$branch" || continue
    # `git fetch <remote> <branch>` updates FETCH_HEAD, not refs/remotes/origin/<branch>.
    tip_rev="FETCH_HEAD"
    if reset_duendee_to "$path" "$tip_rev"; then
      git_with_gh -C "$path" update-ref "refs/remotes/origin/${branch}" "$(git_with_gh -C "$path" rev-parse FETCH_HEAD)" >/dev/null 2>&1 || true
      return 0
    fi
  done
  return 1
}

update_duendee_safe() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  echo -e "  ${DIM}   Duendee güncelleniyor...${RST}" >&2
  if [[ -d "$path/.git" ]] && command -v git >/dev/null 2>&1; then
    if update_duendee_from_git "$path" "$DUENDEE_REPO_URL" \
      || update_duendee_from_git "$path" origin; then
      echo -e "  ${DIM}   Repo güncel.${RST}" >&2
      return 0
    fi
  fi
  refresh_duendee_snapshot "$path"
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
  echo -e "  ${DIM}   İndiriliyor: ${DUENDEE_REPO_URL} -> ${target}${RST}" >&2
  if fetch_public_github "$DUENDEE_REPO_URL" "$target"; then
    (cd "$target" && pwd)
    return 0
  fi
  echo -e "  ${RED}   İndirme başarısız.${RST}" >&2
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
    echo -e "  ${DIM}   Enter=[1]  numara  C=yol  B=klasör  G=klonla${RST}" >&2
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
    echo -e "  ${DIM}   Enter = Desktop'a klonla${RST}" >&2
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
  echo "  WhatsApp baglantisi kontrol ediliyor (${phone:-5315162429})..."
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
    echo -e "  ${DIM}   QR tarayin veya: rm -rf \"$(wa_session_dir)\" sonra tekrar.${RST}"
    echo -e "  ${DIM}   Manuel: node \"${WHATSAPP_JS}\" \"${public_url}\"${RST}"
  else
    echo -e "  ${GRN}   WhatsApp mesaji gonderildi.${RST}"
  fi
}

wa_session_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/duendee-whatsapp"
}

spawn_retract_detached() {
  local wa_js="${WHATSAPP_JS:-${ROOT}/scripts/send-whatsapp.js}"
  local creds="$(wa_session_dir)/creds.json"
  local log="${STATE}/wa-retract.log"
  [[ -f "$wa_js" && -f "$creds" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup env DT_WA_ACTION=retract DT_WA_TIMEOUT_MS=90000 node "$wa_js" --retract >>"$log" 2>&1 </dev/null &
  else
    nohup env DT_WA_ACTION=retract DT_WA_TIMEOUT_MS=90000 node "$wa_js" --retract >>"$log" 2>&1 </dev/null &
  fi
}

retract_tunnel_whatsapp() {
  local wa_js="${WHATSAPP_JS:-${ROOT}/scripts/send-whatsapp.js}"
  local creds="$(wa_session_dir)/creds.json"
  [[ -f "$wa_js" && -f "$creds" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  ensure_whatsapp_deps || return 0
  echo "  Eski tunnel linki mesajlari kaldiriliyor..."
  local ec=0
  DT_WA_ACTION=retract DT_WA_TIMEOUT_MS="${DT_WA_TIMEOUT_MS:-90000}" node "$wa_js" || ec=$?
  if (( ec != 0 )); then
    echo -e "  ${YEL}   Eski WhatsApp link mesaji kaldirilamadi (çıkış ${ec}).${RST}"
  else
    echo -e "  ${GRN}   Gecersiz tunnel linki mesaji kaldirildi.${RST}"
  fi
}

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
      echo -e "  ${YEL}   Node.js bu mimaride otomatik kurulamadı: $(uname -m)${RST}" >&2
      return 1
      ;;
  esac
  dest="${HOME}/.local/share/duendee-node"
  echo "  Node.js kuruluyor (${ver})..."
  tmp="$(mktemp)"
  if ! curl -fsSL -o "$tmp" "https://nodejs.org/dist/${ver}/node-${ver}-linux-${node_arch}.tar.xz"; then
    rm -f "$tmp"
    echo -e "  ${YEL}   Node.js indirilemedi.${RST}" >&2
    return 1
  fi
  mkdir -p "$dest" "${HOME}/.local/bin"
  tar -xJf "$tmp" -C "$dest" --strip-components=1
  rm -f "$tmp"
  ln -sfn "${dest}/bin/node" "${HOME}/.local/bin/node"
  ln -sfn "${dest}/bin/npm" "${HOME}/.local/bin/npm"
  ln -sfn "${dest}/bin/npx" "${HOME}/.local/bin/npx"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

ensure_cloudflared_bin() {
  ensure_local_bin_path
  if command -v cloudflared >/dev/null 2>&1 || [[ -x "${HOME}/.cloudflared/cloudflared" ]]; then
    return 0
  fi
  local name
  case "$(uname -m)" in
    x86_64|amd64) name="cloudflared-linux-amd64" ;;
    aarch64|arm64) name="cloudflared-linux-arm64" ;;
    *)
      echo -e "  ${YEL}   cloudflared bu mimaride otomatik kurulamadı: $(uname -m)${RST}" >&2
      return 1
      ;;
  esac
  echo "  cloudflared kuruluyor..."
  mkdir -p "${HOME}/.cloudflared" "${HOME}/.local/bin"
  if ! curl -fsSL -L -o "${HOME}/.cloudflared/cloudflared" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/${name}"; then
    echo -e "  ${YEL}   cloudflared indirilemedi.${RST}" >&2
    return 1
  fi
  chmod +x "${HOME}/.cloudflared/cloudflared"
  ln -sfn "${HOME}/.cloudflared/cloudflared" "${HOME}/.local/bin/cloudflared"
  ensure_local_bin_path
  hash -r 2>/dev/null || true
}

ensure_requirements() {
  ensure_node || true
  ensure_cloudflared_bin || true
  ensure_whatsapp_deps || true
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
  local spec=""
  if [[ -f "$AUTO_DESKTOP" ]]; then
    spec="$(grep -E '^Exec=' "$AUTO_DESKTOP" 2>/dev/null || true)"
  elif [[ -f "$AUTO_UNIT" ]]; then
    spec="$(grep -E '^ExecStart=' "$AUTO_UNIT" 2>/dev/null || true)"
  elif systemctl --user is-enabled duendee-tunnel-tool.service >/dev/null 2>&1; then
    spec="$(grep -E '^ExecStart=' "$AUTO_UNIT" 2>/dev/null || true)"
  fi
  [[ -n "$spec" ]] || return 0
  if [[ "$spec" == *boot-tunnel* ]]; then
    AUTOMODE=tunnel
  else
    AUTOMODE=tool
  fi
}

browser_opens() {
  [[ "${DT_RECOVER:-}" == "1" ]] && return 1
  local f="${STATE}/open-browser"
  [[ -f "$f" ]] || return 0
  [[ "$(tr -d '[:space:]' <"$f" 2>/dev/null || true)" != "0" ]]
}

set_browser_opens() {
  mkdir -p "$STATE"
  printf '%s\n' "$1" >"${STATE}/open-browser"
}

browser_mark() {
  if browser_opens; then
    printf '%b' "${C5}[TARAYICI]${RST}"
  else
    printf '%b' "${DIM}[TARAYICI KAPALI]${RST}"
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

pid_is_cloudflared() {
  local pid="$1" comm=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "/proc/${pid}/comm" ]] || return 1
  comm="$(tr -d '\0' < "/proc/${pid}/comm" 2>/dev/null || true)"
  [[ "$comm" == "cloudflared" ]]
}

cloudflared_pids() {
  local piddir pid comm argv0
  for piddir in /proc/[0-9]*; do
    pid="${piddir#/proc/}"
    [[ "$pid" == "$$" ]] && continue
    comm="$(tr -d '\0' < "${piddir}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "cloudflared" ]]; then
      printf '%s\n' "$pid"
      continue
    fi
    argv0="$(tr '\0' '\n' < "${piddir}/cmdline" 2>/dev/null | head -n 1 || true)"
    case "$argv0" in
      *cloudflared*) printf '%s\n' "$pid" ;;
    esac
  done
}

cloudflared_alive() {
  local pid
  pid="$(cloudflared_pids | head -n 1 || true)"
  [[ -n "$pid" ]]
}

tunnel_running() {
  read_pid
  if [[ -n "${TPID:-}" ]] && pid_is_cloudflared "$TPID"; then
    return 0
  fi
  cloudflared_alive
}

remember_cloudflared_pid() {
  local pid
  pid="$(cloudflared_pids | head -n 1 || true)"
  [[ -n "$pid" ]] && printf '%s\n' "$pid" >"$PID_FILE"
}

url_from_cloudflared_logs() {
  local pid fd target found
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    for fd in /proc/"$pid"/fd/*; do
      target="$(readlink "$fd" 2>/dev/null || true)"
      [[ -f "$target" ]] || continue
      found="$(grep -Eo 'https://[A-Za-z0-9-]+\.(trycloudflare\.com|cfargotunnel\.com)' "$target" 2>/dev/null | tail -n 1 || true)"
      if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
      fi
    done
  done < <(cloudflared_pids)
  return 1
}

recover_tunnel_url() {
  local found=""
  if cloudflared_alive; then
    found="$(url_from_cloudflared_logs || true)"
  fi
  if [[ -n "$found" ]]; then
    URL="$found"
    mkdir -p "$STATE"
    printf '%s' "$URL" >"$URL_FILE"
    TUNNEL_URL="$URL"
    return 0
  fi
  refresh_url
  [[ -n "${URL:-}" ]]
}

public_url_live() {
  local pub
  [[ -n "${URL:-}" ]] || return 1
  pub="$(http_code "$URL" 4)"
  pub="${pub:-000}"
  (( pub >= 200 && pub <= 399 ))
}

link_already_sent() {
  local want="$1" file
  file="$(wa_session_dir)/sent-links.json"
  [[ -f "$file" && -n "$want" ]] || return 1
  grep -F -q "$want" "$file"
}

kill_tunnel() {
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    if pid_alive "$TPID"; then
      kill -TERM "-$TPID" 2>/dev/null || kill -TERM "$TPID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "-$TPID" 2>/dev/null || kill -KILL "$TPID" 2>/dev/null || true
      echo -e "  ${DIM}   Tünel durduruldu - PID ${TPID}.${RST}"
    fi
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  local cpid
  while IFS= read -r cpid; do
    [[ -n "$cpid" ]] || continue
    kill -TERM "$cpid" 2>/dev/null || true
    kill -KILL "$cpid" 2>/dev/null || true
  done < <(cloudflared_pids)
  rm -f "$PID_FILE" "$URL_FILE"
}

free_listen_port() {
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v lsof >/dev/null 2>&1; then
    local p
    for p in $(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true); do
      kill -KILL "$p" 2>/dev/null || true
    done
  fi
}

origin_serves_broken_bundle() {
  local html js
  html="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  js="$(printf '%s\n' "$html" | sed -n 's/.*src="\(\/assets\/index-[^"]*\.js\)".*/\1/p' | head -n 1)"
  [[ -n "$js" ]] || return 1
  curl -fsS --max-time 8 "http://127.0.0.1:${PORT}${js}" 2>/dev/null | grep -q "Missing Supabase environment variables"
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
      echo -e "  ${DIM}   Dev server durduruldu - PID ${spid}.${RST}"
      stopped=1
    fi
    rm -f "$SERVER_PID"
  fi
  # Fallback: origin started for this project (dev or preview)
  if [[ -n "${PROJECT:-}" ]]; then
    local pat line pid
    for pat in "npm run dev" "vite preview" "npm run build"; do
      while read -r line; do
        [[ "$line" == *"$PROJECT"* ]] || continue
        pid="${line%% *}"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
          kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
          sleep 0.2
          kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
          stopped=1
        fi
      done < <(pgrep -af "$pat" 2>/dev/null || true)
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
    echo -e "  ${DIM}   Aktif tünel servisi yok.${RST}"
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
      echo -e "  ${C4}   Tünel servisi durduruldu - PID ${TPID}.${RST}"
    else
      echo -e "  ${DIM}   PID ${TPID} zaten çalışmıyor.${RST}"
    fi
  else
    echo -e "  ${DIM}   Tanımlı çalışan tünel servisi yok.${RST}"
  fi
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  kill_dev_server
  rm -f "$PID_FILE" "$URL_FILE" "${TMPDIR:-/tmp}/duendee-whatsapp-qr.png"
}

# Closing the tool terminal leaves the tunnel, the app origin, and the link message.
# [4] stops the tunnel.
CLEANING_UP=0
cleanup_quiet() {
  return 0
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
  echo -e "${SALMON}${BOLD}          D U E N D E E   T U N N E L   T O O L${RST}"
  echo -e "${DIM}   ───────────────────────────────────────────────────────────${RST}"
  echo
  echo -e "  ${C1}${BOLD}[1]${RST}  ${C1}Tünel Servisi Başlat${RST}"
  echo -e "  ${C2}${BOLD}[2]${RST}  ${C2}Servis Durumunu Kontrol Et${RST}"
  echo -e "  ${C3}${BOLD}[3]${RST}  ${C3}Yayın Linkini Kopyala${RST}"
  echo -e "  ${C4}${BOLD}[4]${RST}  ${C4}Tünel Servisini İptal Et${RST}"
  case "${AUTOMODE}" in
    tool) echo -e "  ${C5}${BOLD}[5]${RST}  ${C5}Cihaz Açılışında Otomatik Başlat${RST}  ${C5}[TOOL]${RST}  $(browser_mark)" ;;
    tunnel) echo -e "  ${C5}${BOLD}[5]${RST}  ${C5}Cihaz Açılışında Otomatik Başlat${RST}  ${C5}[TOOL+TÜNEL]${RST}  $(browser_mark)" ;;
    *) echo -e "  ${C5}${BOLD}[5]${RST}  ${C5}Cihaz Açılışında Otomatik Başlat${RST}  ${DIM}[KAPALI]${RST}  $(browser_mark)" ;;
  esac
  echo -e "  ${C6}${BOLD}[6]${RST}  ${C6}Aracı Cihazdan Kaldır${RST}"
  echo
  printf "%b" "${DIM}   Seçim: ${RST}"
}

# Public Supabase client values. Clones omit .env, so vite build otherwise
# ships a bundle that throws before the page can render.
DUENDEE_SUPABASE_URL="${DT_VITE_SUPABASE_URL:-https://ytlliifgpbiagidduhsx.supabase.co}"
DUENDEE_SUPABASE_ANON_KEY="${DT_VITE_SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl0bGxpaWZncGJpYWdpZGR1aHN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1NjAyOTAsImV4cCI6MjA4OTEzNjI5MH0.W4p97en1IP7NTF304lCuVsyyvRINqa01yDnwCgOzBj4}"

env_has_supabase() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -Eq '^[[:space:]]*VITE_SUPABASE_URL=https://' "$f" || return 1
  grep -Eq '^[[:space:]]*VITE_SUPABASE_ANON_KEY=eyJ' "$f" || return 1
}

ensure_supabase_env() {
  if env_has_supabase "${PROJECT}/.env" || env_has_supabase "${PROJECT}/.env.local"; then
    return 0
  fi
  local target="${PROJECT}/.env.local"
  umask 077
  cat >"$target" <<EOF
VITE_SUPABASE_URL=${DUENDEE_SUPABASE_URL}
VITE_SUPABASE_ANON_KEY=${DUENDEE_SUPABASE_ANON_KEY}
VITE_APP_VARIANT=main
EOF
  echo -e "  ${DIM}   Supabase istemci ayarı yazıldı (.env yoktu).${RST}"
}

# Vite inlines VITE_* from the process environment with higher priority than .env.
# A clone often has no .env, so the tunnel build must export the public client values.
export_supabase_build_env() {
  local f val
  VITE_SUPABASE_URL="$DUENDEE_SUPABASE_URL"
  VITE_SUPABASE_ANON_KEY="$DUENDEE_SUPABASE_ANON_KEY"
  for f in "${PROJECT}/.env" "${PROJECT}/.env.local" "${PROJECT}/.env.production" "${PROJECT}/.env.production.local"; do
    [[ -f "$f" ]] || continue
    val="$(grep -E '^[[:space:]]*VITE_SUPABASE_URL=https://' "$f" | tail -n1 | cut -d= -f2- | tr -d '\r"' | tr -d "'")"
    [[ -n "$val" ]] && VITE_SUPABASE_URL="$val"
    val="$(grep -E '^[[:space:]]*VITE_SUPABASE_ANON_KEY=eyJ' "$f" | tail -n1 | cut -d= -f2- | tr -d '\r"' | tr -d "'")"
    [[ -n "$val" ]] && VITE_SUPABASE_ANON_KEY="$val"
  done
  export VITE_SUPABASE_URL VITE_SUPABASE_ANON_KEY
  export VITE_APP_VARIANT="${VITE_APP_VARIANT:-main}"
}

bundle_missing_supabase() {
  [[ -d "${PROJECT}/dist/assets" ]] || return 0
  grep -q "Missing Supabase environment variables" "${PROJECT}/dist/assets/"*.js 2>/dev/null
}

app_build_stale() {
  [[ -f "${PROJECT}/dist/index.html" ]] || return 0
  bundle_missing_supabase && return 0
  local newer=""
  newer="$(find "${PROJECT}/src" "${PROJECT}/index.html" "${PROJECT}/.env" "${PROJECT}/.env.local" \
    "${PROJECT}/vite.config.ts" "${PROJECT}/vite.config.js" "${PROJECT}/vite.config.mjs" \
    -newer "${PROJECT}/dist/index.html" -print -quit 2>/dev/null || true)"
  [[ -n "$newer" ]]
}

wait_for_port() {
  local tries=0
  while true; do
    tries=$((tries + 1))
    if port_listening "$PORT"; then
      return 0
    fi
    if (( tries >= 80 )); then
      return 1
    fi
    sleep 0.25
  done
}

launch_app_server() {
  local vite_bin="${PROJECT}/node_modules/.bin/vite"
  if [[ -x "$vite_bin" && ( -f "${PROJECT}/vite.config.ts" || -f "${PROJECT}/vite.config.js" || -f "${PROJECT}/vite.config.mjs" ) ]]; then
    (
      cd "$PROJECT" || exit 1
      setsid "$vite_bin" preview --host 127.0.0.1 --port "$PORT" --strictPort >"${STATE}/server.out.log" 2>&1 &
      echo $! >"$SERVER_PID"
    )
  else
    (
      cd "$PROJECT" || exit 1
      setsid npm run dev >"${STATE}/server.out.log" 2>&1 &
      echo $! >"$SERVER_PID"
    )
  fi
}

build_app_bundle() {
  ensure_supabase_env
  export_supabase_build_env
  if bundle_missing_supabase; then
    rm -rf "${PROJECT}/dist"
  fi
  if app_build_stale; then
    if ! (cd "$PROJECT" && npm run build >"${STATE}/server.build.log" 2>&1); then
      echo -e "  ${RED}${BOLD}   [HATA]${RST} npm run build başarısız."
      echo -e "  ${DIM}   Ayrıntı: ${STATE}/server.build.log${RST}"
      return 1
    fi
  else
    echo -e "  ${DIM}   Mevcut derleme kullanılacak.${RST}"
  fi
}

start_app_origin() {
  local vite_bin="${PROJECT}/node_modules/.bin/vite"
  local attempt
  for attempt in 1 2; do
    if [[ -x "$vite_bin" && ( -f "${PROJECT}/vite.config.ts" || -f "${PROJECT}/vite.config.js" || -f "${PROJECT}/vite.config.mjs" ) ]]; then
      if ! build_app_bundle; then
        return 1
      fi
    else
      ensure_supabase_env
    fi
    launch_app_server
    if ! wait_for_port; then
      return 1
    fi
    if ! origin_serves_broken_bundle; then
      return 0
    fi
    echo -e "  ${DIM}   Sunulan paket Supabase ayarı içermiyor, yeniden derleniyor.${RST}"
    kill_dev_server
    free_listen_port
    rm -rf "${PROJECT}/dist"
    sleep 0.3
  done
  echo -e "  ${RED}${BOLD}   [HATA]${RST} Yayın hâlâ Supabase ayarı olmadan açılıyor."
  return 1
}

file_digest() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    wc -c < "$f" | tr -d '[:space:]'
  fi
}

dep_stamp() {
  local path="$1" name sum=""
  for name in package.json package-lock.json pnpm-lock.yaml yarn.lock; do
    if [[ -f "${path}/${name}" ]]; then
      sum+="$(file_digest "${path}/${name}")"
    else
      sum+="-"
    fi
    sum+="|"
  done
  printf '%s' "$sum"
}

prepare_latest_duendee() {
  if ! looks_like_duendee "$PROJECT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} projectPath Duendee deposu değil. Güncel sürüm yayına alınamadı."
    return 1
  fi
  kill_dev_server
  free_listen_port
  sleep 0.3
  if port_listening "$PORT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} ${PORT} portu boşaltılamadı. Eski yayın durdurulamadı."
    return 1
  fi
  local before after
  before="$(dep_stamp "$PROJECT")"
  if ! update_duendee_safe "$PROJECT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Duendee güncellenemedi. Eski sürüm yayına alınmadı."
    return 1
  fi
  after="$(dep_stamp "$PROJECT")"
  if [[ ! -d "${PROJECT}/node_modules" || "$before" != "$after" ]]; then
    echo -e "  ${DIM}   Bağımlılıklar kuruluyor (npm install)...${RST}"
    if ! (cd "$PROJECT" && npm install); then
      echo -e "  ${RED}${BOLD}   [HATA]${RST} npm install başarısız."
      return 1
    fi
  fi
  rm -rf "${PROJECT}/dist"
  if [[ -f "${PROJECT}/dist/index.html" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Eski derleme silinemedi."
    return 1
  fi
  return 0
}

fleet_node() {
  local n=""
  if command -v node >/dev/null 2>&1; then
    n="$(command -v node)"
  elif [[ -x "${HOME}/.local/bin/node" ]]; then
    n="${HOME}/.local/bin/node"
  fi
  [[ -n "$n" && -f "${ROOT}/scripts/fleet.js" ]] || return 1
  "$n" "${ROOT}/scripts/fleet.js" "$@"
}

fleet_release() {
  fleet_node release --root "$ROOT" >/dev/null 2>&1 || true
}

start_fleet_heartbeat() {
  local hpid="" n=""
  if [[ -f "${STATE}/fleet-heartbeat.pid" ]]; then
    hpid="$(tr -d '[:space:]' < "${STATE}/fleet-heartbeat.pid" || true)"
    if [[ -n "$hpid" ]] && pid_alive "$hpid"; then
      return 0
    fi
  fi
  mkdir -p "$STATE"
  printf '1\n' > "${STATE}/fleet-heartbeat.on"
  if command -v node >/dev/null 2>&1; then
    n="$(command -v node)"
  elif [[ -x "${HOME}/.local/bin/node" ]]; then
    n="${HOME}/.local/bin/node"
  fi
  [[ -n "$n" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys
pidfile, cmd = sys.argv[1], sys.argv[2:]
if os.fork() > 0:
    os._exit(0)
os.setsid()
if os.fork() > 0:
    os._exit(0)
fd = os.open(pidfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, str(os.getpid()).encode())
os.close(fd)
os.execvp(cmd[0], cmd)
' "${STATE}/fleet-heartbeat.pid" "$n" "${ROOT}/scripts/fleet.js" heartbeat --root "$ROOT" >/dev/null 2>&1 &
    wait "$!" 2>/dev/null || true
  else
    setsid nohup "$n" "${ROOT}/scripts/fleet.js" heartbeat --root "$ROOT" >/dev/null 2>&1 &
    echo $! > "${STATE}/fleet-heartbeat.pid"
    disown "$!" 2>/dev/null || true
  fi
}

sync_tool_copy() {
  local ec=0
  [[ "${DT_SKIP_UPDATE:-}" == "1" ]] && return 0
  fleet_node update --root "$ROOT" || ec=$?
  if [[ "$ec" -eq 20 ]]; then
    exec bash "$0" "$@"
  fi
}

public_dns() {
  local host="$1" out addrs
  [[ -n "$host" ]] || return 1
  if command -v nslookup >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 3 nslookup -type=A "$host" 1.1.1.1 2>/dev/null || true)"
    else
      out="$(nslookup -type=A "$host" 1.1.1.1 2>/dev/null || true)"
    fi
    if printf '%s\n' "$out" | grep -Eqi 'NXDOMAIN|Non-existent|can.t find'; then
      return 1
    fi
    addrs="$(printf '%s\n' "$out" | grep -E '^Address: *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '1\.1\.1\.1' || true)"
    [[ -n "$addrs" ]] && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], 443)' "$host" >/dev/null 2>&1 && return 0
  fi
  getent hosts "$host" >/dev/null 2>&1
}

wait_public_ready() {
  local url="$1" seconds="${2:-60}" host deadline now pub flushed=0
  [[ -n "$url" ]] || return 1
  host="$(printf '%s' "$url" | sed -E 's#^https://([^/]+).*#\1#')"
  deadline=$(( $(date +%s) + seconds ))
  while true; do
    now="$(date +%s)"
    (( now >= deadline )) && return 1
    if ! tunnel_running; then
      return 1
    fi
    pub="$(http_code "$url" 8)"
    pub="${pub:-000}"
    if (( pub >= 200 && pub <= 399 )); then
      return 0
    fi
    sleep 2
  done
}

launch_cloudflared() {
  local target="http://127.0.0.1:${PORT}"
  pkill -f "cloudflared tunnel --url" 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -f "$URL_FILE" "$LOG" "$OUT_LOG" "$PID_FILE"
  URL=""
  TUNNEL_URL=""
  PREV=""
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys
pidfile, cmd = sys.argv[1], sys.argv[2:]
if os.fork() > 0:
    os._exit(0)
os.setsid()
if os.fork() > 0:
    os._exit(0)
fd = os.open(pidfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(fd, str(os.getpid()).encode())
os.close(fd)
os.execvp(cmd[0], cmd)
' "$PID_FILE" "$CF" tunnel --url "$target" --http-host-header "127.0.0.1:${PORT}" --no-autoupdate --protocol http2 --edge-ip-version 4 --retries 5 >"$OUT_LOG" 2>"$LOG" </dev/null &
    local helper=$! pid_wait
    for pid_wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [[ -s "$PID_FILE" ]] && break
      sleep 0.1
    done
    wait "$helper" 2>/dev/null || true
  else
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$CF" tunnel --url "$target" --http-host-header "127.0.0.1:${PORT}" --no-autoupdate --protocol http2 --edge-ip-version 4 --retries 5 >"$OUT_LOG" 2>"$LOG" </dev/null &
    else
      nohup "$CF" tunnel --url "$target" --http-host-header "127.0.0.1:${PORT}" --no-autoupdate --protocol http2 --edge-ip-version 4 --retries 5 >"$OUT_LOG" 2>"$LOG" </dev/null &
    fi
    echo $! >"$PID_FILE"
    disown "$!" 2>/dev/null || true
  fi
  read_pid
  [[ -n "${TPID:-}" ]] || return 1
  sleep 0.3
  pid_alive "$TPID"
}

await_tunnel_url() {
  local tries=0
  URL=""
  while true; do
    refresh_url
    [[ -n "${URL:-}" ]] && return 0
    tries=$((tries + 1))
    if (( tries % 20 == 0 )); then
      echo -e "  ${DIM}   ... $((tries / 4)) saniye beklendi${RST}"
    fi
    if ! pid_alive "${TPID:-0}"; then
      return 1
    fi
    if (( tries >= 180 )); then
      return 1
    fi
    sleep 0.25
  done
}

open_resolving_tunnel() {
  echo -e "  ${C1}[4]${RST} Tünel açılıyor..."
  if ! launch_cloudflared; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel süreci başlamadı."
    logtail
    kill_tunnel
    return 1
  fi
  if ! await_tunnel_url; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel adresi oluşmadı."
    logtail
    kill_tunnel
    return 1
  fi
  if ! tunnel_running; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel süreci kapandı."
    logtail
    kill_tunnel
    return 1
  fi
  return 0
}

do_start() {
  if [[ "${DT_RECOVER:-}" != "1" ]]; then
    rm -f "${STATE}/manual-stop"
  fi
  clear
  echo
  echo -e "${C1}   --- Tünel servisi başlatılıyor ---${RST}"
  echo

  if ! find_cloudflared; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} cloudflared bulunamadı."
    wait_key
    return
  fi
  echo -e "  ${C1}[1]${RST} cloudflared: $CF"

  local local_url="" decision=""
  mkdir -p "$STATE"
  rm -f "${STATE}/fleet-claimed"
  if tunnel_running; then
    recover_tunnel_url || true
    local_url="${URL:-}"
  fi
  if ! decision="$(fleet_node begin --root "$ROOT" --local-alive "$(if tunnel_running; then echo 1; else echo 0; fi)" --local-url "${local_url:--}" 2>"${STATE}/fleet-begin.err")"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel kaydı okunamadı. Yeni tünel açılmadı."
    if [[ -s "${STATE}/fleet-begin.err" ]]; then
      echo -e "  ${DIM}   $(tr '\n' ' ' < "${STATE}/fleet-begin.err")${RST}"
    fi
    wait_key
    return
  fi
  case "$decision" in
    adopt$'\t'*)
      URL="${decision#*$'\t'}"
      if tunnel_running; then
        kill_tunnel
      fi
      mkdir -p "$STATE"
      printf '%s' "$URL" >"$URL_FILE"
      echo -e "  ${C1}   Aktif tünel var.${RST}"
      echo -e "${C1}${BOLD}     ${URL}${RST}"
      copy_clipboard "$URL" >/dev/null 2>&1 || true
      echo
      wait_key
      return
      ;;
    keep|keep$'\t'*)
      if [[ "$decision" == keep$'\t'* ]]; then
        URL="${decision#*$'\t'}"
        printf '%s' "$URL" >"$URL_FILE"
      fi
      remember_cloudflared_pid
      start_fleet_heartbeat
      echo -e "  ${C1}   Aktif tünel var.${RST}"
      recover_tunnel_url || true
      ;;
    own)
      : > "${STATE}/fleet-claimed"
      trap 'trap - RETURN; if [[ -f "${STATE}/fleet-claimed" ]]; then rm -f "${STATE}/fleet-claimed"; fleet_release; fi' RETURN
      ;;
    *)
      echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel kaydı okunamadı. Yeni tünel açılmadı."
      wait_key
      return
      ;;
  esac
  local fresh=0
  if [[ "$decision" == keep || "$decision" == keep$'\t'* ]]; then
    if ! port_listening "$PORT"; then
      echo -e "  ${DIM}   Yerel uygulama kapalı, aynı tünel için açılıyor...${RST}"
      start_app_origin || echo -e "  ${RED}   Uygulama açılamadı. Tünel duruyor ama sayfa erişilemeyebilir.${RST}"
    fi
    recover_tunnel_url || true
    if [[ -z "${URL:-}" ]]; then
      echo -e "  ${DIM}   Tünel çalışıyor ama yayın linki okunamadı. Kapatmak için [4].${RST}"
      wait_key
      return
    fi
    echo -e "${C1}${BOLD}     ${URL}${RST}"
    copy_clipboard "$URL" >/dev/null 2>&1 || true
    echo
    wait_key
    return
  fi
  read_pid
  if [[ -n "${TPID:-}" ]]; then
    rm -f "$PID_FILE" "$URL_FILE"
  fi

  if [[ "$fresh" -eq 0 ]]; then
    echo -e "  ${C1}[2]${RST} Güncel Duendee yayına alınıyor..."
    if ! prepare_latest_duendee; then
      wait_key
      return
    fi
    echo -e "  ${C1}[3]${RST} Uygulama başlatılıyor..."
    if ! start_app_origin; then
      echo -e "  ${RED}${BOLD}[HATA]${RST} Uygulama ${PORT} portunda açılamadı."
      echo -e "  ${DIM}   Ayrıntı: ${STATE}/server.out.log${RST}"
      wait_key
      return
    fi
  elif ! port_listening "$PORT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Uygulama ${PORT} portunda açılamadı."
    wait_key
    return
  fi
  echo -e "  ${DIM}   Uygulama http://127.0.0.1:${PORT} hazır.${RST}"

  if ! open_resolving_tunnel; then
    kill_tunnel
    wait_key
    return
  fi
  if ! port_listening "$PORT"; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Dev server origin ${PORT} portunda yanıt vermiyor."
    logtail
    kill_tunnel
    wait_key
    return
  fi
  refresh_url
  echo
  echo -e "${C1}${BOLD}"
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
      echo -e "${DIM}   Link panoya kopyalandı.${RST}  Gerekirse [3] ile yeniden kopyalayın."
    else
      echo -e "${DIM}   Panoya kopyalanamadı (xclip/wl-copy yok). Link:${RST}"
    fi
    echo -e "${C1}${BOLD}     ${URL}${RST}"
    echo
    if browser_opens; then
      echo "  Varsayılan tarayıcıda açılıyor..."
      open_url "$URL"
    else
      echo -e "  ${DIM}   Tarayıcı kapalı. [5] > [B].${RST}"
    fi
    send_tunnel_whatsapp "$URL"
  fi
  if [[ -f "${STATE}/fleet-claimed" || "$fresh" -eq 1 ]]; then
    if ! fleet_node publish --root "$ROOT" --url "$URL"; then
      if [[ -f "${STATE}/fleet-claimed" ]]; then
        echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel kaydı yazılamadı. Yerel tünel kapatıldı."
        kill_tunnel
        rm -f "${STATE}/fleet-claimed"
        trap - RETURN
        fleet_release
        wait_key
        return
      fi
      echo -e "  ${DIM}   Yeni adres kayda yazılamadı. Yerel yayın duruyor.${RST}"
    fi
    rm -f "${STATE}/fleet-claimed"
    trap - RETURN
    start_fleet_heartbeat
  fi
  echo
  wait_key
}

do_status() {
  clear
  echo
  echo -e "${C2}   --- Servis Durumu ---${RST}"
  echo
  if port_listening "$PORT"; then
    echo -e "  ${C2}Dev Server ........ ÇALIŞIYOR${RST}  -  http://localhost:${PORT}"
  else
    echo -e "  ${DIM}Dev Server ........ KAPALI${RST}"
  fi
  local fleet_url="" local_url="" running=0 public_ok=0 pub="000"
  if tunnel_running; then
    running=1
    remember_cloudflared_pid
    recover_tunnel_url || true
    local_url="${URL:-}"
    if [[ -n "$local_url" ]]; then
      pub="$(http_code "$local_url" 8)"
      pub="${pub:-000}"
      if (( pub >= 200 && pub <= 399 )); then
        public_ok=1
      fi
    fi
  fi
  if [[ "$public_ok" -eq 1 ]]; then
    DT_FLEET_QUIET=1 fleet_node publish --root "$ROOT" --url "$local_url" >/dev/null 2>&1 || true
    start_fleet_heartbeat
  else
    fleet_url="$(fleet_node show --root "$ROOT" 2>/dev/null || true)"
  fi
  if [[ "$public_ok" -eq 1 || -n "$fleet_url" ]]; then
    URL="${local_url:-$fleet_url}"
    if [[ "$public_ok" -ne 1 ]]; then
      URL="$fleet_url"
    fi
    echo -e "  ${C2}Tünel Servisi ..... ÇALIŞIYOR${RST}"
    echo -e "  ${C2}Yayın Linki ......... ${BOLD}${URL}${RST}"
  elif [[ "$running" -eq 1 ]]; then
    echo -e "  ${C2}Tünel Servisi ..... ÇALIŞIYOR${RST}"
    if [[ -n "$local_url" ]]; then
      echo -e "  ${C2}Yayın Linki ......... ${BOLD}${local_url}${RST}"
      echo -e "  ${DIM}   Adres henüz dışarıdan yanıt vermiyor.${RST}"
    else
      echo -e "  ${DIM}   Yayın linki okunamadı.${RST}"
    fi
  else
    echo -e "  ${DIM}Tünel Servisi ..... KAPALI${RST}"
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
  local fleet_url=""
  if tunnel_running; then
    refresh_url || true
    if [[ -n "${URL:-}" ]]; then
      local pub
      pub="$(http_code "$URL" 8)"
      pub="${pub:-000}"
      if (( pub < 200 || pub > 399 )); then
        URL=""
      fi
    fi
  fi
  if [[ -z "${URL:-}" ]]; then
    fleet_url="$(fleet_node show --root "$ROOT" 2>/dev/null || true)"
  fi
  if [[ -z "${URL:-}" && -z "$fleet_url" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Aktif yayın linki yok."
    echo -e "  ${DIM}   Önce [1] ile tünel servisini başlatın.${RST}"
    echo
    wait_key
    return
  fi
  if [[ -n "$fleet_url" ]]; then
    URL="$fleet_url"
  else
    refresh_url
  fi
  if [[ -z "${URL:-}" ]]; then
    echo -e "  ${RED}${BOLD}[HATA]${RST} Aktif yayın linki yok."
    echo -e "  ${DIM}   Önce [1] ile tünel servisini başlatın.${RST}"
    echo
    wait_key
    return
  fi
  if copy_clipboard "$URL"; then
    echo -e "${C3}   Yayın linki panoya kopyalandı:${RST}"
  else
    echo -e "${C3}   Panoya kopyalanamadı (xclip/wl-copy yok):${RST}"
  fi
  echo -e "${C3}${BOLD}     ${URL}${RST}"
  echo
  wait_key
}

do_cancel() {
  clear
  echo
  echo -e "${C4}   --- Tünel servisini iptal et ---${RST}"
  echo
  mkdir -p "$STATE"
  printf '1\n' >"${STATE}/manual-stop"
  kill_tunnel
  kill_dev_server
  local fleet_role="none"
  fleet_role="$(fleet_node role --root "$ROOT" 2>/dev/null || echo none)"
  if [[ "$fleet_role" == "other" ]]; then
    echo -e "  ${C4}   Aktif tünel kapatılıyor...${RST}"
    fleet_node stop --root "$ROOT" >/dev/null 2>&1 || true
  fi
  fleet_node clear --root "$ROOT" >/dev/null 2>&1 || true
  URL=""
  TUNNEL_URL=""
  PREV=""
  retract_tunnel_whatsapp
  echo -e "  ${C4}   Tünel kapatıldı.${RST}"
  echo
  wait_key
}

write_terminal_opener() {
  local opener="${HOME}/.local/bin/duendee-tunnel-open"
  mkdir -p "${HOME}/.local/bin"
  cat >"$opener" <<'EOF'
#!/bin/sh
tool="${HOME}/.local/bin/duendee-tunnel"
[ -x "$tool" ] || exit 1
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- "$tool" "$@"
  fi
  if command -v kgx >/dev/null 2>&1; then
    exec kgx -- "$tool" "$@"
  fi
  if command -v ptyxis >/dev/null 2>&1; then
    exec ptyxis -- "$tool" "$@"
  fi
  if command -v xfce4-terminal >/dev/null 2>&1; then
    exec xfce4-terminal -e "$tool $*"
  fi
  if command -v konsole >/dev/null 2>&1; then
    exec konsole -e "$tool" "$@"
  fi
  if command -v xterm >/dev/null 2>&1; then
    exec xterm -e "$tool" "$@"
  fi
  if command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -e "$tool" "$@"
  fi
fi
exec "$tool" "$@"
EOF
  chmod +x "$opener"
  printf '%s\n' "$opener"
}

write_autostart_unit() {
  local arg="${1:-}"
  local opener exec_line
  opener="$(write_terminal_opener)" || return 1
  mkdir -p "$AUTO_DESKTOP_DIR"
  if [[ -n "$arg" ]]; then
    exec_line="${opener} ${arg}"
  else
    exec_line="${opener}"
  fi
  cat >"$AUTO_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Duendee Tunnel Tool
Comment=Duendee Tunnel Tool
Exec=${exec_line}
Terminal=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF
  chmod +x "$AUTO_DESKTOP" 2>/dev/null || true
  systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
  rm -f "$AUTO_UNIT"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  return 0
}

install_desktop_shortcut() {
  local desk icon launcher dest app
  desk="$(desktop_dir)"
  [[ -n "$desk" ]] || return 0
  mkdir -p "$desk" "${HOME}/.local/share/applications"
  icon="${OS_DIR}/duendee-tunnel-tool.png"
  [[ -f "$icon" ]] || return 0
  launcher="${HOME}/.local/bin/duendee-tunnel"
  [[ -x "$launcher" ]] || launcher="${OS_DIR}/duendee-tunnel-tool.sh"
  dest="${desk}/Duendee Tunnel Tool.desktop"
  app="${HOME}/.local/share/applications/duendee-tunnel-tool.desktop"
  cat >"$dest" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Duendee Tunnel Tool
Comment=Duendee Tunnel Tool
Exec=${launcher}
Icon=${icon}
Terminal=true
Categories=Network;
StartupNotify=true
EOF
  cp "$dest" "$app"
  chmod +x "$dest" "$app" 2>/dev/null || true
  if command -v gio >/dev/null 2>&1; then
    gio set "$dest" metadata::trusted true >/dev/null 2>&1 || true
  fi
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
  install_desktop_shortcut || true
  if [[ -f "$AUTO_DESKTOP" || -f "$AUTO_UNIT" ]]; then
    local arg=""
    if [[ -f "$AUTO_DESKTOP" ]] && grep -q 'boot-tunnel' "$AUTO_DESKTOP"; then
      arg="boot-tunnel"
    elif [[ -f "$AUTO_UNIT" ]] && grep -q 'boot-tunnel' "$AUTO_UNIT"; then
      arg="boot-tunnel"
    fi
    write_autostart_unit "$arg" || true
  fi
}

disable_autostart() {
  systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
  rm -f "$AUTO_UNIT" "$AUTO_DESKTOP" "${HOME}/.local/bin/duendee-tunnel-open"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

do_autostart() {
  local ans="" choices="TSBX"
  clear
  echo
  echo -e "${C5}   --- Cihaz Açılışında Otomatik Başlat ---${RST}"
  echo
  autostate
  case "$AUTOMODE" in
    tool) echo -e "  ${DIM}   Durum:${RST} ${C5}${BOLD}[TOOL]${RST}" ;;
    tunnel) echo -e "  ${DIM}   Durum:${RST} ${C5}${BOLD}[TOOL+TÜNEL]${RST}" ;;
    *) echo -e "  ${DIM}   Durum:${RST} ${RED}${BOLD}[KAPALI]${RST}" ;;
  esac
  echo
  if browser_opens; then
    echo -e "  ${DIM}   Tarayıcı:${RST} ${C5}${BOLD}[AÇIK]${RST}"
  else
    echo -e "  ${DIM}   Tarayıcı:${RST} ${DIM}${BOLD}[KAPALI]${RST}"
  fi
  echo
  echo -e "  ${C5}${BOLD}[T]${RST}  ${C5}Yalnızca tool'u otomatik başlat${RST}"
  echo -e "  ${C5}${BOLD}[S]${RST}  ${C5}Tool'u ve tünel servisini otomatik başlat${RST}"
  echo -e "  ${C5}${BOLD}[B]${RST}  ${C5}Tünel başladığında tarayıcıyı aç / kapat${RST}"
  if [[ "$AUTOMODE" != "off" ]]; then
    echo -e "  ${C5}${BOLD}[K]${RST}  ${C5}Otomatik başlatmayı kapat${RST}"
    choices="TSBKX"
  fi
  echo -e "  ${DIM}${BOLD}[X]${RST}  ${DIM}Geri dön${RST}"
  echo
  printf "%b" "${DIM}   Seçim: ${RST}"
  read -r -n 1 ans
  echo
  case "${ans^^}" in
    T)
      if [[ "$AUTOMODE" == "tool" ]]; then
        echo -e "  ${DIM}   Bu ayar zaten seçili.${RST}"
      elif write_autostart_unit ""; then
        echo -e "  ${C5}   Yalnızca tool otomatik başlayacak.${RST}"
        echo -e "  ${DIM}   Kayıt: ${AUTO_DESKTOP}${RST}"
      else
        echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kaydedilemedi."
      fi
      ;;
    S)
      if [[ "$AUTOMODE" == "tunnel" ]]; then
        echo -e "  ${DIM}   Bu ayar zaten seçili.${RST}"
      elif write_autostart_unit "boot-tunnel"; then
        echo -e "  ${C5}   Tool ve tünel servisi otomatik başlayacak.${RST}"
        echo -e "  ${DIM}   Kayıt: ${AUTO_DESKTOP}${RST}"
      else
        echo -e "  ${RED}${BOLD}[HATA]${RST} Ayar kaydedilemedi."
      fi
      ;;
    B)
      if browser_opens; then
        set_browser_opens 0
        echo -e "  ${C5}   Tünel başladığında tarayıcı açılmayacak.${RST}"
      else
        set_browser_opens 1
        echo -e "  ${C5}   Tünel başladığında tarayıcı açılacak.${RST}"
      fi
      ;;
    K)
      [[ "$AUTOMODE" == "off" ]] && return 0
      disable_autostart
      autostate
      echo
      if [[ "$AUTOMODE" == "off" ]]; then
        echo -e "  ${C5}   Otomatik başlatma kapatıldı.${RST}"
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
    6|uninstall|kaldir|kaldır|remove) return 0 ;;
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
  echo -e "  ${DIM}   - Masaüstü kısayolu: $(desktop_dir)/Duendee Tunnel Tool.desktop${RST}"
  if [[ "$mode" == "2" ]]; then
    echo -e "  ${DIM}   - Node.js${RST}"
    echo -e "  ${DIM}   - cloudflared${RST}"
  fi
}

do_uninstall() {
  local mode="${1:-}"
  local ans=""
  clear
  echo
  echo -e "${C6}   --- Aracı Kaldır ---${RST}"
  echo
  if [[ "$mode" != "1" && "$mode" != "2" ]]; then
    echo -e "  ${C6}${BOLD}[1]${RST}  ${C6}Yalnızca Duendee Tunnel Tool${RST}"
    echo -e "  ${C6}${BOLD}[2]${RST}  ${C6}Tool, Node.js ve cloudflared${RST}"
    echo -e "  ${DIM}${BOLD}[X]${RST}  ${DIM}Vazgeç${RST}"
    echo
    printf "%b" "${DIM}   Seçim [1/2/X]: ${RST}"
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
  printf "%b" "${DIM}   [E] Evet, kaldır    [H] Hayır: ${RST}"
  read -r -n 1 ans
  echo
  case "${ans^^}" in
    E) ;;
    *)
      echo
      echo -e "  ${DIM}   Kaldırma iptal edildi.${RST}"
      if [[ -z "${UNINSTALL_CLI:-}" ]]; then
        wait_key
      fi
      return 0
      ;;
  esac

  echo
  retract_tunnel_whatsapp
  CLEANING_UP=1
  kill_all || true
  systemctl --user disable --now duendee-tunnel-tool.service >/dev/null 2>&1 || true
  rm -f "$AUTO_UNIT" "$AUTO_DESKTOP" "$(desktop_dir)/Duendee Tunnel Tool.desktop" \
    "${HOME}/.local/share/applications/duendee-tunnel-tool.desktop" 2>/dev/null || true
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
      echo -e "  ${RED}   Silinemedi: ${dir}${RST}"
    else
      echo -e "  ${C6}   Silindi: ${dir}${RST}"
    fi
  done
  echo
  echo -e "  ${C6}   Kaldırma tamam.${RST}"
  echo
  exit 0
}

do_shutdown() {
  clear
  echo
  echo -e "${C4}   --- Tüm terminaller kapatılıyor ---${RST}"
  local fleet_role="none"
  fleet_role="$(fleet_node role --root "$ROOT" 2>/dev/null || echo none)"
  if [[ "$fleet_role" == "other" ]]; then
    echo -e "  ${C4}   Aktif tünel kapatılıyor...${RST}"
    if fleet_node stop --root "$ROOT"; then
      retract_tunnel_whatsapp
      echo -e "  ${C4}   Tünel servisi kapatıldı. Çıkılıyor...${RST}"
    else
      echo -e "  ${RED}${BOLD}[HATA]${RST} Tünel servisi kapatılamadı.${RST}"
    fi
    echo
    exit 0
  fi
  retract_tunnel_whatsapp
  kill_all
  fleet_release
  CLEANING_UP=1
  echo -e "${C4}   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...${RST}"
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
ensure_requirements
sync_tool_copy "$@"
trap cleanup_quiet EXIT INT TERM HUP
register_stable_launch || true

if [[ "${1:-}" == "boot-tunnel" ]]; then
  do_start
elif [[ "${1:-}" == "recover-tunnel" ]]; then
  if [[ -f "${STATE}/manual-stop" ]]; then
    exit 0
  fi
  export DT_WA_TEMPLATE='Tünel zaman aşımına uğradı, yeni tünel linki: {url}'
  export DT_RECOVER=1
  AUTO=1
  do_start
  exit 0
elif [[ "${1:-}" != "" ]]; then
  AUTO=1
  case "$1" in
    1) do_start; exit 0 ;;
    2) do_status; exit 0 ;;
    3) do_copylink; exit 0 ;;
    4) do_cancel; exit 0 ;;
    5) do_autostart; exit 0 ;;
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
    5) do_autostart ;;
    6) do_uninstall ;;
    *) ;;
  esac
done
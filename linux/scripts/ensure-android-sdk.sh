#!/usr/bin/env bash
# Ensures a user-local JDK 17 + Android SDK sufficient to assembleDebug.
# Prints: JAVA_HOME=... and ANDROID_SDK_ROOT=... on success (stdout).
set -euo pipefail

COMPILE_SDK="${1:-35}"
BUILD_TOOLS="${2:-35.0.0}"
TOOL_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/duendee-tunnel"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"

info() { echo "  $*" >&2; }
fail() { echo "  [HATA] $*" >&2; exit 1; }

java_home_ok() {
  local home="$1" ver
  [[ -n "$home" && -x "$home/bin/java" ]] || return 1
  ver="$("$home/bin/java" -version 2>&1 || true)"
  # Capacitor 7 Android compile needs JDK 21+.
  [[ "$ver" =~ version\ \"2[1-9] ]]
}

find_java_home() {
  local c root
  for c in "${JAVA_HOME:-}" "$TOOL_HOME/jdk" "$TOOL_HOME/jdk-21"; do
    java_home_ok "$c" && { (cd "$c" && pwd); return 0; }
  done
  for root in /usr/lib/jvm /usr/lib64/jvm "$HOME/.sdkman/candidates/java"; do
    [[ -d "$root" ]] || continue
    for c in "$root"/*; do
      java_home_ok "$c" && { (cd "$c" && pwd); return 0; }
    done
  done
  if command -v java >/dev/null 2>&1; then
    c="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    java_home_ok "$c" && { echo "$c"; return 0; }
  fi
  return 1
}

install_jdk() {
  mkdir -p "$TOOL_HOME"
  if command -v apt-get >/dev/null 2>&1; then
    info "JDK 21 deneniyor (apt openjdk-21-jdk-headless)..."
    if sudo -n true 2>/dev/null; then
      sudo -n apt-get install -y openjdk-21-jdk-headless >/dev/null 2>&1 || true
    fi
  fi
  if find_java_home; then return 0; fi
  info "JDK 21 indiriliyor (Eclipse Temurin)..."
  local arch url tgz stage dest
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) fail "Desteklenmeyen mimari: $(uname -m)" ;;
  esac
  url="https://api.adoptium.net/v3/binary/latest/21/ga/linux/${arch}/jdk/hotspot/normal/eclipse?project=jdk"
  tgz="$TOOL_HOME/jdk21.tar.gz"
  stage="$TOOL_HOME/jdk-stage"
  dest="$TOOL_HOME/jdk"
  curl -fsSL "$url" -o "$tgz"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf "$tgz" -C "$stage"
  rm -f "$tgz"
  local inner
  inner="$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$inner" ]] || fail "JDK arşivi boş."
  rm -rf "$dest"
  mv "$inner" "$dest"
  rm -rf "$stage"
  java_home_ok "$dest" || fail "JDK 21 kurulumu doğrulanamadı."
  (cd "$dest" && pwd)
}

sdkmanager_path() {
  local root="$1" p
  for p in \
    "$root/cmdline-tools/latest/bin/sdkmanager" \
    "$root/cmdline-tools/bin/sdkmanager"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  local d
  for d in "$root"/cmdline-tools/*; do
    [[ -x "$d/bin/sdkmanager" ]] && { echo "$d/bin/sdkmanager"; return 0; }
  done
  return 1
}

install_cmdline_tools() {
  local root="$1" sm
  if sm="$(sdkmanager_path "$root")"; then echo "$sm"; return 0; fi
  info "Android cmdline-tools indiriliyor..."
  mkdir -p "$root" "$TOOL_HOME"
  local zip="$TOOL_HOME/cmdline-tools.zip" stage="$TOOL_HOME/cmdline-stage"
  local url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  curl -fsSL "$url" -o "$zip"
  rm -rf "$stage"
  mkdir -p "$stage"
  unzip -q "$zip" -d "$stage"
  rm -f "$zip"
  local src="$stage/cmdline-tools"
  [[ -d "$src" ]] || src="$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -d "$src" ]] || fail "cmdline-tools arşivi beklenen yapıda değil."
  mkdir -p "$root/cmdline-tools"
  rm -rf "$root/cmdline-tools/latest"
  mv "$src" "$root/cmdline-tools/latest"
  rm -rf "$stage"
  sm="$(sdkmanager_path "$root")" || fail "sdkmanager bulunamadı."
  echo "$sm"
}

install_sdk_packages() {
  local root="$1" java_home="$2" sm="$3"
  export JAVA_HOME="$java_home"
  export ANDROID_SDK_ROOT="$root"
  export ANDROID_HOME="$root"
  export PATH="$java_home/bin:$PATH"
  local need=0
  [[ -d "$root/platforms/android-${COMPILE_SDK}" ]] || need=1
  [[ -d "$root/build-tools/${BUILD_TOOLS}" ]] || need=1
  [[ -d "$root/platform-tools" ]] || need=1
  (( need == 0 )) && return 0
  info "Android SDK paketleri kuruluyor (platform/build-tools)..."
  yes | "$sm" --sdk_root="$root" --licenses >/dev/null 2>&1 || true
  "$sm" --sdk_root="$root" --install \
    "platforms;android-${COMPILE_SDK}" \
    "build-tools;${BUILD_TOOLS}" \
    platform-tools
  [[ -d "$root/platforms/android-${COMPILE_SDK}" ]] || fail "platforms;android-${COMPILE_SDK} eksik"
  [[ -d "$root/build-tools/${BUILD_TOOLS}" ]] || fail "build-tools;${BUILD_TOOLS} eksik"
  [[ -d "$root/platform-tools" ]] || fail "platform-tools eksik"
}

JAVA_HOME_VAL="$(find_java_home || install_jdk)"
SDKMANAGER="$(install_cmdline_tools "$SDK_ROOT")"
install_sdk_packages "$SDK_ROOT" "$JAVA_HOME_VAL" "$SDKMANAGER"
echo "JAVA_HOME=${JAVA_HOME_VAL}"
echo "ANDROID_SDK_ROOT=${SDK_ROOT}"
exit 0

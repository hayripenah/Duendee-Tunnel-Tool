# Ensures a user-local JDK 17 + Android SDK sufficient to assembleDebug.
# Prints: JAVA_HOME=... and ANDROID_SDK_ROOT=... on success (stdout).
param(
  [int]$CompileSdk = 35,
  [string]$BuildTools = '35.0.0'
)

$ErrorActionPreference = 'Stop'
$toolHome = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel'
$sdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
  elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME }
  else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

function Write-Info([string]$msg) { Write-Host "  $msg" }
function Fail([string]$msg) { Write-Host "  [HATA] $msg"; exit 1 }

function Save-UrlToFile([string]$Url, [string]$OutFile) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
  if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    Write-Info "İndiriliyor (curl): $Url"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & curl.exe -L --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 600 -o $OutFile $Url
      $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile) -or ((Get-Item -LiteralPath $OutFile).Length -lt 1024)) {
      Fail "İndirme başarısız (curl exit $code): $Url"
    }
    return
  }
  Write-Info "İndiriliyor (WebRequest): $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
  if (-not (Test-Path -LiteralPath $OutFile) -or ((Get-Item -LiteralPath $OutFile).Length -lt 1024)) {
    Fail "İndirme başarısız: $Url"
  }
}

function Test-JavaHome([string]$JdkHome) {
  if ([string]::IsNullOrWhiteSpace($JdkHome)) { return $false }
  $java = Join-Path $JdkHome 'bin\java.exe'
  if (-not (Test-Path -LiteralPath $java)) { return $false }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $java -version 2>&1 | Out-String
  } finally { $ErrorActionPreference = $prev }
  # Capacitor 7 Android compile needs JDK 21+.
  return ($out -match 'version "?2[1-9]')
}

function Find-JavaHome {
  foreach ($c in @(
      $env:JAVA_HOME,
      (Join-Path $toolHome 'jdk'),
      (Join-Path $toolHome 'jdk-21')
    )) {
    if (Test-JavaHome $c) { return (Resolve-Path -LiteralPath $c).Path }
  }
  foreach ($root in @(
      (Join-Path ${env:ProgramFiles} 'Eclipse Adoptium'),
      (Join-Path ${env:ProgramFiles} 'Microsoft'),
      (Join-Path ${env:ProgramFiles} 'Java'),
      (Join-Path ${env:ProgramFiles} 'Android\Android Studio\jbr'),
      (Join-Path ${env:LOCALAPPDATA} 'Programs\Android\Android Studio\jbr')
    )) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    if (Test-JavaHome $root) { return (Resolve-Path -LiteralPath $root).Path }
    $kids = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'jdk|jbr|temurin|ms-' })
    foreach ($kid in $kids) {
      if (Test-JavaHome $kid.FullName) { return $kid.FullName }
    }
  }
  $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
  if ($cmd) {
    $bin = Split-Path -Parent $cmd.Source
    $jdkHome = Split-Path -Parent $bin
    if (Test-JavaHome $jdkHome) { return $jdkHome }
  }
  return $null
}

function Install-Jdk {
  $dest = Join-Path $toolHome 'jdk'
  if (Test-JavaHome $dest) { return (Resolve-Path -LiteralPath $dest).Path }
  New-Item -ItemType Directory -Force -Path $toolHome | Out-Null
  # Portable Temurin 21 — no admin. Capacitor Android needs source/target 21.
  Write-Info 'JDK 21 indiriliyor (Eclipse Temurin, portable)...'
  $zip = Join-Path $toolHome 'jdk21.zip'
  $url = 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk'
  Save-UrlToFile -Url $url -OutFile $zip
  $stage = Join-Path $toolHome 'jdk-stage'
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $inner = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
  if (-not $inner) { Fail 'JDK arşivi boş.' }
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  Move-Item -LiteralPath $inner.FullName -Destination $dest
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-JavaHome $dest)) { Fail 'JDK 21 kurulumu doğrulanamadı.' }
  return (Resolve-Path -LiteralPath $dest).Path
}

function Get-SdkManager([string]$root) {
  foreach ($rel in @(
      'cmdline-tools\latest\bin\sdkmanager.bat',
      'cmdline-tools\bin\sdkmanager.bat'
    )) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) { return $p }
  }
  $dirs = @(Get-ChildItem -LiteralPath (Join-Path $root 'cmdline-tools') -Directory -ErrorAction SilentlyContinue)
  foreach ($d in $dirs) {
    $p = Join-Path $d.FullName 'bin\sdkmanager.bat'
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Install-CmdlineTools([string]$root) {
  $sm = Get-SdkManager $root
  if ($sm) { return $sm }
  Write-Info 'Android cmdline-tools indiriliyor...'
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $zip = Join-Path $toolHome 'cmdline-tools.zip'
  $url = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'
  Save-UrlToFile -Url $url -OutFile $zip
  $stage = Join-Path $toolHome 'cmdline-stage'
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $src = Join-Path $stage 'cmdline-tools'
  if (-not (Test-Path -LiteralPath $src)) {
    $first = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
    if ($first) { $src = $first.FullName }
  }
  if (-not $src -or -not (Test-Path -LiteralPath $src)) { Fail 'cmdline-tools arşivi beklenen yapıda değil.' }
  $dest = Join-Path $root 'cmdline-tools\latest'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  Move-Item -LiteralPath $src -Destination $dest
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  $sm = Get-SdkManager $root
  if (-not $sm) { Fail 'sdkmanager bulunamadı.' }
  return $sm
}

function Install-SdkPackages([string]$root, [string]$javaHome, [string]$sdkmanager) {
  $env:JAVA_HOME = $javaHome
  $env:ANDROID_SDK_ROOT = $root
  $env:ANDROID_HOME = $root
  $env:Path = "$(Join-Path $javaHome 'bin');$env:Path"
  $packages = @(
    "platforms;android-$CompileSdk",
    "build-tools;$BuildTools",
    'platform-tools'
  )
  $need = $false
  foreach ($pkg in $packages) {
    $rel = if ($pkg.StartsWith('platforms;')) { "platforms\android-$CompileSdk" }
      elseif ($pkg.StartsWith('build-tools;')) { "build-tools\$BuildTools" }
      else { 'platform-tools' }
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) { $need = $true; break }
  }
  if (-not $need) { return }
  Write-Info 'Android SDK paketleri kuruluyor (platform/build-tools)...'
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $yes = "y`n" * 80
    $yes | & cmd.exe /c "`"$sdkmanager`" --sdk_root=`"$root`" --licenses" 2>&1 | Out-Null
    & cmd.exe /c "`"$sdkmanager`" --sdk_root=`"$root`" --install $($packages -join ' ')" 2>&1 | Out-Host
  } finally {
    $ErrorActionPreference = $prev
  }
  foreach ($pkg in $packages) {
    $rel = if ($pkg.StartsWith('platforms;')) { "platforms\android-$CompileSdk" }
      elseif ($pkg.StartsWith('build-tools;')) { "build-tools\$BuildTools" }
      else { 'platform-tools' }
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) {
      Fail "SDK paketi eksik: $pkg"
    }
  }
}

$javaHome = Find-JavaHome
if (-not $javaHome) { $javaHome = Install-Jdk }
Write-Info "JAVA_HOME=$javaHome"
$sdkmanager = Install-CmdlineTools $sdkRoot
Install-SdkPackages -root $sdkRoot -javaHome $javaHome -sdkmanager $sdkmanager

Write-Output "JAVA_HOME=$javaHome"
Write-Output "ANDROID_SDK_ROOT=$sdkRoot"
exit 0

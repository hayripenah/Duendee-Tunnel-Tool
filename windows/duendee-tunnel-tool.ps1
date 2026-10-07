#Requires -Version 5.1
# Duendee Tunnel Tool (Windows) — UTF-8 UI so Turkish stays correct for the whole session.
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Action = ''
)

$ErrorActionPreference = 'Continue'
$OsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $OsDir
Set-Location -LiteralPath $Root

function Initialize-Utf8Console {
  try { chcp 65001 | Out-Null } catch {}
  $utf8 = New-Object System.Text.UTF8Encoding $false
  try {
    [Console]::OutputEncoding = $utf8
    [Console]::InputEncoding = $utf8
  } catch {}
  $global:OutputEncoding = $utf8
  $env:PYTHONIOENCODING = 'utf-8'
  try { $Host.UI.RawUI.WindowTitle = 'Duendee Tunnel Tool' } catch {}
}

function Write-Ui([string]$Text) { [Console]::Write($Text) }
function Write-UiLine([string]$Text = '') { [Console]::WriteLine($Text) }

function Pause-Enter {
  Write-UiLine ''
  Write-Ui 'Devam etmek için bir tuşa basın . . . '
  try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { [void](Read-Host) }
  Write-UiLine ''
}

function Get-Choice([string]$Choices) {
  while ($true) {
    try {
      $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
      $ch = $key.Character.ToString().ToUpperInvariant()
    } catch {
      $raw = (Read-Host).Trim()
      if ($raw.Length -lt 1) { continue }
      $ch = $raw.Substring(0, 1).ToUpperInvariant()
    }
    if ($Choices.ToUpperInvariant().Contains($ch)) { return $ch }
  }
}

Initialize-Utf8Console

$Esc = [char]27
$RST = "$Esc[0m"; $BOLD = "$Esc[1m"; $DIM = "$Esc[2m"
$CYN = "$Esc[96m"; $YEL = "$Esc[93m"; $GRN = "$Esc[92m"; $RED = "$Esc[91m"
$BLUE = "$Esc[38;2;59;130;246m"; $DEEP = "$Esc[38;2;30;64;175m"; $SKY = "$Esc[38;2;147;197;253m"

$configPath = Join-Path $Root 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
  Write-UiLine "  $RED$BOLD[HATA]$RST config.json bulunamadı. Önce config.example.json dosyasını config.json olarak kopyalayıp projectPath ayarlayın."
  Pause-Enter
  exit 1
}

try {
  $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-UiLine "  $RED$BOLD[HATA]$RST config.json okunamadı: $($_.Exception.Message)"
  Pause-Enter
  exit 1
}

$Project = [string]$cfg.projectPath
$Port = if ($cfg.port) { [int]$cfg.port } else { 8080 }
if ([string]::IsNullOrWhiteSpace($Project)) {
  Write-UiLine "  $RED$BOLD[HATA]$RST config.json içinde projectPath tanımlı değil."
  Pause-Enter
  exit 1
}
if (-not (Test-Path -LiteralPath $Project)) {
  Write-UiLine "  $RED$BOLD[HATA]$RST projectPath bulunamadı: $Project"
  Pause-Enter
  exit 1
}

$StateDir = Join-Path $Root '.tunnelstate'
$PidFile = Join-Path $StateDir 'tunnel.pid'
$UrlFile = Join-Path $StateDir 'tunnel.url'
$LogFile = Join-Path $StateDir 'tunnel.log'
$OutLogFile = Join-Path $StateDir 'tunnel.out.log'
$ServerPidFile = Join-Path $StateDir 'server.pid'
if (-not (Test-Path -LiteralPath $StateDir)) {
  New-Item -ItemType Directory -Path $StateDir | Out-Null
}

$script:AutoMode = -not [string]::IsNullOrWhiteSpace($Action)
$env:PROJECT = $Project
$env:SERVER_PID = $ServerPidFile
$env:PID_FILE = $PidFile
$env:URL_FILE = $UrlFile
$env:LOG = $LogFile
$env:OUT_LOG = $OutLogFile

function Get-AutoEnabled {
  $null -ne (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue)
}

function Read-TunnelPid {
  if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
  $raw = (Get-Content -LiteralPath $PidFile -TotalCount 1 -ErrorAction SilentlyContinue)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $id = 0
  if ([int]::TryParse($raw.Trim(), [ref]$id)) { return $id }
  return $null
}

function Test-PidAlive([int]$ProcessId) {
  if ($ProcessId -le 0) { return $false }
  try { return $null -ne (Get-Process -Id $ProcessId -ErrorAction Stop) } catch { return $false }
}

function Test-PortListening([int]$PortNum) {
  try {
    if (Get-NetTCPConnection -LocalPort $PortNum -State Listen -ErrorAction SilentlyContinue) { return $true }
  } catch {}
  $out = netstat -ano 2>$null | Select-String -Pattern ":$PortNum\s" | Select-String 'LISTENING'
  return [bool]$out
}

function Find-Cloudflared {
  if ($env:DT_CF -and (Test-Path -LiteralPath $env:DT_CF)) { return $env:DT_CF }
  $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($c in @(
      'C:\Program Files (x86)\cloudflared\cloudflared.exe',
      (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
      (Join-Path $env:USERPROFILE '.cloudflared\cloudflared.exe')
    )) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

function Start-ToolWatcher {
  $watcher = Join-Path $OsDir 'scripts\tunnel-watcher.ps1'
  if (-not (Test-Path -LiteralPath $watcher)) { return }
  Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $watcher, '-ToolPid', "$PID", '-Project', $Project, '-ToolRoot', $Root
  ) | Out-Null
}

function Invoke-ExtractUrl {
  $extract = Join-Path $OsDir 'scripts\extract-tunnel-url.ps1'
  if (-not (Test-Path -LiteralPath $extract)) { return }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $extract -Log $LogFile -OutLog $OutLogFile -UrlFile $UrlFile | Out-Null
}

function Get-TunnelUrl {
  Invoke-ExtractUrl
  if (-not (Test-Path -LiteralPath $UrlFile)) { return $null }
  $u = (Get-Content -LiteralPath $UrlFile -Raw -ErrorAction SilentlyContinue)
  if ([string]::IsNullOrWhiteSpace($u)) { return $null }
  return $u.Trim()
}

function Show-LogTail {
  Write-UiLine "  $DIM   Son log:$RST"
  if (-not (Test-Path -LiteralPath $LogFile)) { return }
  foreach ($s in (Get-Content -LiteralPath $LogFile -Tail 8 -ErrorAction SilentlyContinue)) {
    $t = $s
    $t = $t -replace '^ERR ', 'Hata: '
    $t = $t -replace '^WRN ', 'Uyarı: '
    $t = $t -replace '^INF ', 'Bilgi: '
    $t = $t -replace 'precheck complete', 'ön kontrol tamamlandı'
    $t = $t -replace 'Registered tunnel connection', 'tünel bağlantısı kuruldu'
    $t = $t -replace 'Unable to reach the origin', 'yerel sunucu (origin) erişilemiyor'
    $t = $t -replace 'connection refused', 'bağlantı reddedildi'
    $t = $t -replace 'error=', 'hata='
    $color = 'Gray'
    if ($s -match 'ERR') { $color = 'Red' }
    elseif ($s -match 'WRN') { $color = 'Yellow' }
    elseif ($s -match 'INF') { $color = 'Green' }
    Write-Host ("    " + $t) -ForegroundColor $color
  }
}

function Test-TunnelRunning {
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) { return $true }
  if (Get-Process cloudflared -ErrorAction SilentlyContinue) { return $true }
  return $false
}

function Stop-TunnelOnly {
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Stop-Process -Id $tpid -Force -ErrorAction SilentlyContinue
    Write-UiLine "  $GRN   Tünel durduruldu - PID $tpid.$RST"
  }
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
}

function Stop-AllToolProcesses {
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Stop-Process -Id $tpid -Force -ErrorAction SilentlyContinue
    Write-UiLine "  $GRN   Tünel servisi durduruldu - PID $tpid.$RST"
  } elseif ($tpid) {
    Write-UiLine "  $DIM   PID $tpid zaten çalışmıyor.$RST"
  } else {
    Write-UiLine "  $YEL   Tanımlı çalışan tünel servisi yok.$RST"
  }
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $ServerPidFile) {
    $spidRaw = Get-Content -LiteralPath $ServerPidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $spid = 0
    if ([int]::TryParse("$spidRaw".Trim(), [ref]$spid) -and (Test-PidAlive $spid)) {
      Stop-Process -Id $spid -Force -ErrorAction SilentlyContinue
      Write-UiLine "  $GRN   Dev server penceresi kapatıldı - PID $spid.$RST"
    } else {
      Write-UiLine "  $DIM   Dev server zaten kapalı.$RST"
    }
    Remove-Item -LiteralPath $ServerPidFile -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  Get-Process PhotosApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'duendee-whatsapp-qr.png') -Force -ErrorAction SilentlyContinue
}

function Show-Logo {
  $rows = @(
    '##### #   # ##### #   # ##### ##### #####',
    '#   # #   # #     ##  # #   # #     #',
    '#   # #   # #     # # # #   # #     #',
    '#   # #   # ##### #  ## #   # ##### #####',
    '#   # #   # #     #   # #   # #     #',
    '#   # #   # #     #   # #   # #     #',
    '##### ##### ##### #   # ##### ##### #####'
  )
  Write-UiLine ''
  foreach ($r in $rows) {
    Write-UiLine ("$BLUE$BOLD    $r$RST")
    Write-UiLine ("$DEEP      $r$RST")
  }
  Write-UiLine ''
  Write-UiLine "$DIM   -----------------------------------------------------------$RST"
  Write-UiLine "$SKY$BOLD          D U E N D E E   T U N N E L   T O O L$RST"
  Write-UiLine "$DIM   -----------------------------------------------------------$RST"
  Write-UiLine ''
}

function Show-Menu {
  Initialize-Utf8Console
  Clear-Host
  $autoOn = Get-AutoEnabled
  Show-Logo
  Write-UiLine "  $YEL$BOLD[1]$RST  ${SKY}Tünel Servisi Başlat$RST"
  Write-UiLine "  $YEL$BOLD[2]$RST  ${SKY}Servis Durumunu Kontrol Et$RST"
  Write-UiLine "  $YEL$BOLD[3]$RST  ${SKY}Yayın Linkini Kopyala$RST"
  Write-UiLine "  $YEL$BOLD[4]$RST  ${SKY}Tünel Servisini İptal Et$RST"
  Write-UiLine "  $YEL$BOLD[5]$RST  ${SKY}Tüm Terminalleri Kapat ve Çık$RST"
  if ($autoOn) {
    Write-UiLine "  $YEL$BOLD[6]$RST  ${SKY}Cihaz Açılışında Otomatik Başlat$RST  $GRN[AÇIK]$RST"
  } else {
    Write-UiLine "  $YEL$BOLD[6]$RST  ${SKY}Cihaz Açılışında Otomatik Başlat$RST  $DIM[KAPALI]$RST"
  }
  Write-UiLine ''
  Write-UiLine "$DIM      Kapatmak için pencereyi kapatın, [Ctrl]+[C] ya da [5]$RST"
  Write-UiLine ''
  Write-Ui "$CYN   Seçim [1-6]: $RST"
}

function Complete-Action {
  Write-UiLine ''
  if ($script:AutoMode) { exit 0 }
  Pause-Enter
}

function Invoke-Status {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Servis Durumu ---$RST"
  Write-UiLine ''
  if (Test-PortListening $Port) {
    Write-UiLine "  Dev Server ........ ${GRN}ÇALIŞIYOR$RST  -  http://localhost:$Port"
  } else {
    Write-UiLine "  Dev Server ........ ${RED}KAPALI$RST"
  }
  $tpid = Read-TunnelPid
  $alive = $tpid -and (Test-PidAlive $tpid)
  if ($alive) {
    Write-UiLine "  Tünel Servisi ..... ${GRN}ÇALIŞIYOR$RST  -  PID $tpid"
    $url = Get-TunnelUrl
    if ($url) { Write-UiLine "  Yayın Linki ......... $BLUE$BOLD$url$RST" }
  } else {
    Write-UiLine "  Tünel Servisi ..... ${RED}KAPALI$RST"
  }
  if (Test-Path -LiteralPath $LogFile) { Show-LogTail }
  Complete-Action
}

function Invoke-CopyLink {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  $tpid = Read-TunnelPid
  $alive = $tpid -and (Test-PidAlive $tpid)
  $url = if ($alive) { Get-TunnelUrl } else { $null }
  if (-not $url) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Aktif yayın linki yok."
    Write-UiLine "  $DIM   Önce [1] ile tünel servisini başlatın.$RST"
    Complete-Action
    return
  }
  Set-Clipboard -Value $url
  Write-UiLine "  $GRN   Yayın linki panoya kopyalandı:$RST"
  Write-UiLine "  $BLUE$BOLD     $url$RST"
  Complete-Action
}

function Invoke-Start {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Tünel servisi başlatılıyor ---$RST"
  Write-UiLine ''

  $cf = Find-Cloudflared
  if (-not $cf) {
    Write-UiLine "  $RED$BOLD[HATA]$RST cloudflared bulunamadı."
    Complete-Action
    return
  }
  Write-UiLine "  ${CYN}[1/4]$RST cloudflared: $cf"
  $env:CF = $cf

  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Servis zaten çalışıyor. Önce [4] ile iptal edin."
    Complete-Action
    return
  }
  if ($tpid) { Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue }

  if (-not (Test-PortListening $Port)) {
    Write-UiLine "  ${CYN}[2/4]$RST Dev server başlatılıyor..."
    if (-not (Test-Path -LiteralPath (Join-Path $Project 'node_modules'))) {
      Write-UiLine "  $DIM   node_modules yok, npm install çalıştırılıyor...$RST"
      Push-Location $Project
      try {
        & npm install
        if ($LASTEXITCODE -ne 0) {
          Write-UiLine "  $RED$BOLD   [HATA]$RST npm install başarısız."
          Complete-Action
          return
        }
      } finally { Pop-Location }
    }
    $p = Start-Process -FilePath cmd.exe -ArgumentList '/C', "cd /d `"$Project`" & npm run dev" -WindowStyle Minimized -PassThru
    if ($p) { Set-Content -LiteralPath $ServerPidFile -Value $p.Id -Encoding Ascii }
    $ready = $false
    for ($i = 1; $i -le 20; $i++) {
      if (Test-PortListening $Port) { $ready = $true; break }
      Start-Sleep -Seconds 1
    }
    if (-not $ready) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Dev server $Port portunda açılamadı."
      Write-UiLine "  $DIM   npm run dev çıktısını ayrı bir pencerede deneyin.$RST"
      Complete-Action
      return
    }
    Write-UiLine "  ${CYN}[2/4]$RST Dev server http://localhost:$Port hazır."
  } else {
    Write-UiLine "  ${CYN}[2/4]$RST Dev server $Port portunda hazır."
  }

  Write-UiLine "  ${CYN}[3/4]$RST Cloudflare tünel başlatılıyor..."
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $UrlFile, $LogFile, $OutLogFile -Force -ErrorAction SilentlyContinue
  $target = "http://localhost:$Port"
  $tp = Start-Process -FilePath $cf -ArgumentList @('tunnel', '--url', $target, '--no-autoupdate') `
    -WindowStyle Minimized -PassThru -RedirectStandardOutput $OutLogFile -RedirectStandardError $LogFile
  if (-not $tp) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel başlatılamadı. Log: $LogFile"
    Complete-Action
    return
  }
  Set-Content -LiteralPath $PidFile -Value $tp.Id -Encoding Ascii
  Start-Sleep -Seconds 1
  if (-not (Test-PidAlive $tp.Id)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel açılır açılmaz çıktı. Son log:"
    Show-LogTail
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  Write-UiLine "  ${CYN}[4/4]$RST Yayın linki bekleniyor - 60 sn'ye kadar..."
  $url = $null
  for ($tries = 1; $tries -le 60; $tries++) {
    $url = Get-TunnelUrl
    if ($url) { break }
    if (-not (Test-PidAlive $tp.Id)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Tünel çıktı, link alınamadı. Son log:"
      Show-LogTail
      Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
      Complete-Action
      return
    }
    if (($tries % 5) -eq 0) { Write-UiLine "  $DIM   ... $tries saniye beklendi$RST" }
    Start-Sleep -Seconds 1
  }
  if (-not $url) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Yayın linki alınamadı - 60 sn doldu. Son log:"
    Show-LogTail
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  Write-UiLine "  $DIM   Link alındı, origin sağlığı doğrulanıyor...$RST"
  $origOk = $false
  $code = '000'
  for ($tries = 1; $tries -le 15; $tries++) {
    try { $code = & curl.exe -s -o nul -w '%{http_code}' --max-time 4 "http://localhost:$Port" } catch { $code = '000' }
    if (-not $code) { $code = '000' }
    $n = 0
    if ([int]::TryParse("$code", [ref]$n) -and $n -ge 200 -and $n -le 399) {
      Write-UiLine "  $GRN   Origin kontrolü başarılı, kod: $code.$RST"
      $origOk = $true
      break
    }
    if (-not (Test-PidAlive $tp.Id)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Tünel bağlantı sırasında çıktı."
      Show-LogTail
      Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
      Complete-Action
      return
    }
    Start-Sleep -Seconds 1
  }
  if (-not $origOk) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Dev server origin $Port portunda yanıt vermiyor, son kod: $code."
    Write-UiLine "  $DIM   000 = bağlantı kurulamadı; npm run dev penceresini kontrol edin.$RST"
    Show-LogTail
    Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  $pub = '000'
  $pubOk = $false
  for ($tries = 1; $tries -le 3; $tries++) {
    $url = Get-TunnelUrl
    try { $pub = & curl.exe -s -o nul -w '%{http_code}' --max-time 6 $url } catch { $pub = '000' }
    if (-not $pub) { $pub = '000' }
    $n = 0
    if ([int]::TryParse("$pub", [ref]$n) -and $n -ge 200 -and $n -le 399) {
      Write-UiLine "  $GRN   Yayın adresi erişilebilir, kod: $pub - yayın hazır.$RST"
      $pubOk = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $pubOk) {
    Write-UiLine "  $YEL   Uyarı: halk adres henüz doğrulanamadı, son kod: $pub.$RST"
    Write-UiLine "  $DIM   000 = Cloudflare henüz yönlendirmiyor; birkaç saniye içinde erişilebilir olur.$RST"
  }

  $url = Get-TunnelUrl
  Write-UiLine ''
  Write-UiLine "$GRN$BOLD"
  Write-UiLine '  +======================================================+'
  Write-UiLine '  |      YAYIN HAZIR - Diğer cihazlar bağlanabilir!      |'
  Write-UiLine '  +======================================================+'
  Write-UiLine "$RST"
  Write-UiLine ''
  Show-LogTail
  Write-UiLine ''
  if ($url) {
    Set-Clipboard -Value $url
    Write-UiLine "  $BLUE$BOLD     $url$RST"
    Write-UiLine "  $GRN   Link panoya kopyalandı.$RST  Gerekirse [3] ile yeniden kopyalayın."
    Write-UiLine ''
    Write-UiLine '  Varsayılan tarayıcıda açılıyor...'
    Start-Process $url
    Write-UiLine "  WhatsApp'a link gönderiliyor..."
    & node (Join-Path $Root 'scripts\send-whatsapp.js') $UrlFile '+905315162429'
  }
  Complete-Action
}

function Invoke-Cancel {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Tünel servisini iptal et ---$RST"
  Write-UiLine ''
  if (-not (Test-TunnelRunning)) {
    Write-UiLine "  $YEL   Aktif tünel servisi yok.$RST"
    Write-UiLine "  $DIM   İptal edilecek bir şey yok. Başlatmak için menüden [1] kullanın.$RST"
    Complete-Action
    return
  }
  Stop-TunnelOnly
  Write-UiLine "  $GRN   Tünel iptal edildi. Yeni tünel otomatik başlatılmadı.$RST"
  Complete-Action
}

function Invoke-Autostart {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Cihaz Açılışında Otomatik Başlat ---$RST"
  Write-UiLine ''
  $batLauncher = Join-Path $OsDir 'Duendee Tunnel Tool.bat'
  if (Get-AutoEnabled) {
    Write-UiLine "  $DIM   Durum:$RST $YEL$BOLD[AÇIK]$RST"
    Write-UiLine "  $DIM   Cihaz açıldığında tool kendiliğinden açılır, servisi [1] ile elle başlatırsın.$RST"
    Write-UiLine ''
    Write-Ui '   Otomatik başlatmayı kapat  [K]   -   geri dön  [X]: '
    $c = Get-Choice 'KX'
    Write-UiLine ''
    if ($c -eq 'X') { return }
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue
    if (-not (Get-AutoEnabled)) {
      Write-UiLine "  $GRN   Otomatik başlatma kapatıldı.$RST"
    } else {
      Write-UiLine "  $RED$BOLD[HATA]$RST Ayar kapatılamadı."
    }
  } else {
    Write-UiLine "  $DIM   Durum:$RST $RED$BOLD[KAPALI]$RST"
    Write-UiLine "  $DIM   Cihaz açıldığında tool açılmıyor.$RST"
    Write-UiLine ''
    Write-Ui '   Otomatik başlatmayı aç  [A]   -   geri dön  [X]: '
    $c = Get-Choice 'AX'
    Write-UiLine ''
    if ($c -eq 'X') { return }
    $val = '"' + $batLauncher + '"'
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -Value $val -PropertyType String -Force | Out-Null
    if (Get-AutoEnabled) {
      Write-UiLine "  $GRN   Otomatik başlatma açık.$RST"
      Write-UiLine "  $DIM   Kayıt: HKCU\...\Run - DuendeeTunnelTool$RST"
    } else {
      Write-UiLine "  $RED$BOLD[HATA]$RST Ayar kaydedilemedi."
    }
  }
  Complete-Action
}

function Invoke-Shutdown {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Tüm terminaller kapatılıyor ---$RST"
  Stop-AllToolProcesses
  Write-UiLine "  $GRN   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...$RST"
  Write-UiLine ''
  exit 0
}

Start-ToolWatcher

switch ($Action) {
  '1' { Invoke-Start; exit 0 }
  '2' { Invoke-Status; exit 0 }
  '3' { Invoke-CopyLink; exit 0 }
  '4' { Invoke-Cancel; exit 0 }
  '5' { Invoke-Shutdown }
  '6' { Invoke-Autostart; exit 0 }
}

while ($true) {
  Show-Menu
  $choice = Get-Choice '123456'
  Write-UiLine ''
  switch ($choice) {
    '1' { Invoke-Start }
    '2' { Invoke-Status }
    '3' { Invoke-CopyLink }
    '4' { Invoke-Cancel }
    '5' { Invoke-Shutdown }
    '6' { Invoke-Autostart }
  }
}

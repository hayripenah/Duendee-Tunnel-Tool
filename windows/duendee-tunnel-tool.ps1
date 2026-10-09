#Requires -Version 5.1
# Duendee Tunnel Tool (Windows) — UTF-8 UI so Turkish stays correct for the whole session.
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Action = '',
  [Parameter(Position = 1)]
  [string]$UninstallChoice = ''
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
$BLUE = "$Esc[38;2;59;130;246m"; $SKY = "$Esc[38;2;147;197;253m"
# Claude Code–style warm salmon for the DUENDEE banner
$SALMON = "$Esc[38;2;232;113;90m"

$configPath = Join-Path $Root 'config.json'
$configExample = Join-Path $Root 'config.example.json'
$script:DuendeeRepoUrl = if ($env:DT_DUENDEE_REPO_URL) { $env:DT_DUENDEE_REPO_URL } else { 'https://github.com/hayripenah/Duendee.git' }
$script:DuendeeCloneName = if ($env:DT_DUENDEE_CLONE_NAME) { $env:DT_DUENDEE_CLONE_NAME } else { 'Duendee-main' }

function Save-ToolConfig([string]$ProjectPath, [int]$PortNum) {
  $obj = [ordered]@{ projectPath = $ProjectPath; port = $PortNum }
  ($obj | ConvertTo-Json -Depth 4) + "`n" | Set-Content -LiteralPath $configPath -Encoding UTF8 -NoNewline
}

function Get-UserDesktopPath {
  try {
    $p = [Environment]::GetFolderPath('Desktop')
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  } catch {}
  $fallback = Join-Path $env:USERPROFILE 'Desktop'
  if (-not (Test-Path -LiteralPath $fallback)) {
    New-Item -ItemType Directory -Force -Path $fallback | Out-Null
  }
  return $fallback
}

function Test-LooksLikeDuendeeRepo([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $leaf = Split-Path -Leaf $Path
  $nameHit = $leaf -match '^(?i)duendee(-main)?$'
  $pkg = Join-Path $Path 'package.json'
  $pkgHit = $false
  if (Test-Path -LiteralPath $pkg) {
    try {
      $raw = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8
      if ($raw -match 'hayripenah' -or $raw -match 'dev:tunnel' -or $raw -match 'vite_react_shadcn' -or
          ($raw -match '"dev"\s*:\s*"vite"' -and $nameHit)) { $pkgHit = $true }
    } catch {}
  }
  $remoteHit = $false
  $gitDir = Join-Path $Path '.git'
  if (Test-Path -LiteralPath $gitDir) {
    try {
      $remote = (& git -C $Path remote get-url origin 2>$null)
      if ($remote -and ($remote -match '(?i)github\.com[:/].*hayripenah/Duendee(\.git)?/?$' -or
          ($remote -match '(?i)/Duendee(\.git)?/?$' -and $remote -notmatch '(?i)Tunnel-Tool'))) {
        $remoteHit = $true
      }
    } catch {}
  }
  return ($remoteHit -or ($nameHit -and $pkgHit) -or ($pkgHit -and (Test-Path -LiteralPath $gitDir)))
}

function Install-UserGh {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $ver = '2.102.0'
  $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
  $zip = Join-Path $env:TEMP "gh-$ver-win.zip"
  $dest = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\gh'
  Write-UiLine '  GitHub CLI kuruluyor (tek sefer)...'
  try {
    Invoke-WebRequest -Uri "https://github.com/cli/cli/releases/download/v$ver/gh_${ver}_windows_${arch}.zip" -OutFile $zip -UseBasicParsing
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
  } catch {
    Write-UiLine "  $YEL   GitHub CLI indirilemedi.$RST"
    return $null
  }
  $exe = Get-ChildItem -Path $dest -Filter gh.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { return $null }
  $bin = Split-Path -Parent $exe.FullName
  if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
  return $exe.FullName
}

function Save-PublicGitHubTree([string]$RepoUrl, [string]$Target) {
  $repo = $RepoUrl -replace '\.git$', '' -replace '^https://github.com/', '' -replace '^git@github.com:', ''
  $zip = Join-Path $env:TEMP ("duendee-src-" + [guid]::NewGuid().ToString('n') + '.zip')
  $unpack = Join-Path $env:TEMP ("duendee-src-" + [guid]::NewGuid().ToString('n'))
  foreach ($branch in @('main', 'master')) {
    try {
      Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip -UseBasicParsing
      if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
      Expand-Archive -Path $zip -DestinationPath $unpack -Force
      $inner = Get-ChildItem -LiteralPath $unpack -Directory | Select-Object -First 1
      if ($inner) {
        $parent = Split-Path -Parent $Target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
        Move-Item -LiteralPath $inner.FullName -Destination $Target
        return $true
      }
    } catch {}
  }
  $gh = Install-UserGh
  if (-not $gh) { return $false }
  & $gh auth status 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-UiLine '  Private repo. GitHub CLI girişi bir kez istenir; şifre repoya yazılmaz.'
    & $gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { return $false }
  }
  $parent = Split-Path -Parent $Target
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $env:GH_PROMPT_DISABLED = '1'
  & $gh repo clone $repo $Target -- --depth 1
  $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $Target)
  return $ok
}

function Update-DuendeeRepoSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
  try {
    $env:GIT_TERMINAL_PROMPT = '0'
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    $cred = @('-c', 'credential.helper=')
    if ($gh) {
      & $gh.Source auth status 1>$null 2>$null
      if ($LASTEXITCODE -eq 0) { $cred = @('-c', 'credential.helper=!gh auth git-credential') }
    }
    $dirty = (& git @cred -C $Path status --porcelain 2>$null)
    if ($dirty) {
      Write-UiLine "  $DIM   Git: yerel değişiklikler var — pull atlandı ($Path)$RST"
      return
    }
    Write-UiLine "  $DIM   Duendee güncelleniyor (git fetch/pull --ff-only)...$RST"
    $env:GIT_TERMINAL_PROMPT = '0'
    & git @cred -C $Path fetch --quiet 2>$null | Out-Null
    & git @cred -C $Path pull --ff-only --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-UiLine "  $GRN   Repo güncel.$RST"
    } else {
      Write-UiLine "  $YEL   Pull atlandı/başarısız (ff-only). Mevcut kopya kullanılacak.$RST"
    }
  } catch {
    Write-UiLine "  $YEL   Git güncelleme atlandı: $($_.Exception.Message)$RST"
  }
}

function Find-LocalDuendeeRepos {
  $desktop = Get-UserDesktopPath
  $userHome = $env:USERPROFILE
  $docs = [Environment]::GetFolderPath('MyDocuments')
  $candidates = New-Object System.Collections.Generic.List[string]
  $add = {
    param([string]$p)
    if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) {
      $full = (Resolve-Path -LiteralPath $p).Path
      if (-not $candidates.Contains($full)) { [void]$candidates.Add($full) }
    }
  }
  if ($env:DT_DUENDEE_DIR) { & $add $env:DT_DUENDEE_DIR }
  foreach ($base in @($desktop, $userHome, $docs, (Join-Path $userHome 'YEK\Cursor'), (Join-Path $desktop 'YEK\Cursor'), (Join-Path $userHome 'Cursor'), (Join-Path $desktop 'Cursor'))) {
    if (-not $base) { continue }
    foreach ($name in @('Duendee-main', 'Duendee', 'duendee-main', 'duendee')) {
      & $add (Join-Path $base $name)
    }
  }
  foreach ($scanRoot in @($desktop, $docs, $userHome, (Join-Path $userHome 'YEK'), (Join-Path $desktop 'YEK'))) {
    if (-not $scanRoot -or -not (Test-Path -LiteralPath $scanRoot)) { continue }
    try {
      Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(?i)duendee(-main)?$'
      } | ForEach-Object { & $add $_.FullName }
      Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cursor = Join-Path $_.FullName 'Cursor'
        if (Test-Path -LiteralPath $cursor) {
          Get-ChildItem -LiteralPath $cursor -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(?i)duendee(-main)?$'
          } | ForEach-Object { & $add $_.FullName }
        }
      }
    } catch {}
  }
  $hits = @()
  foreach ($c in $candidates) {
    if (Test-LooksLikeDuendeeRepo $c) { $hits += $c }
  }
  return $hits
}

function Select-FolderBrowser([string]$Description) {
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    $dlg.SelectedPath = (Get-UserDesktopPath)
    $res = $dlg.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
      return $dlg.SelectedPath
    }
  } catch {}
  return $null
}

function Clone-DuendeeTo([string]$ParentDir) {
  if (-not (Test-Path -LiteralPath $ParentDir)) {
    New-Item -ItemType Directory -Force -Path $ParentDir | Out-Null
  }
  $target = Join-Path $ParentDir $script:DuendeeCloneName
  if (Test-Path -LiteralPath $target) {
    if (Test-LooksLikeDuendeeRepo $target) {
      Update-DuendeeRepoSafe $target
      return (Resolve-Path -LiteralPath $target).Path
    }
    Write-UiLine "  $YEL   Klasör zaten var ama Duendee görünmüyor: $target$RST"
    return $null
  }
  Write-UiLine "  $DIM   İndiriliyor: $($script:DuendeeRepoUrl) -> $target$RST"
  if (-not (Save-PublicGitHubTree -RepoUrl $script:DuendeeRepoUrl -Target $target)) {
    Write-UiLine "  $RED   İndirme başarısız.$RST"
    return $null
  }
  return (Resolve-Path -LiteralPath $target).Path
}

function Resolve-ProjectPathInteractive([string]$CurrentProj) {
  $desktop = Get-UserDesktopPath
  Write-UiLine "  $YEL$BOLD[KURULUM]$RST Duendee proje klasörü (projectPath)."
  Write-UiLine "  $DIM   Varsayılan konum: Desktop ($desktop)$RST"
  if (-not [string]::IsNullOrWhiteSpace($CurrentProj) -and -not (Test-Path -LiteralPath $CurrentProj)) {
    Write-UiLine "  $DIM   Mevcut config değeri geçersiz: $CurrentProj$RST"
  }
  Write-UiLine ''

  $found = @(Find-LocalDuendeeRepos)
  if ($found.Count -gt 0) {
    Write-UiLine "  $GRN   Yerel Duendee bulundu:$RST"
    for ($i = 0; $i -lt $found.Count; $i++) {
      Write-UiLine ("  $DIM   [{0}] {1}$RST" -f ($i + 1), $found[$i])
    }
    Write-UiLine ''
    Write-UiLine "  $DIM   Enter = [1] kullan ve güncelle | numara | C = özel yol | B = klasör seç | G = Desktop'a klonla$RST"
    Write-Ui '  seçim> '
    $choice = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') {
      $path = $found[0]
      Update-DuendeeRepoSafe $path
      return $path
    }
    if ($choice -match '^\d+$') {
      $idx = [int]$choice - 1
      if ($idx -ge 0 -and $idx -lt $found.Count) {
        Update-DuendeeRepoSafe $found[$idx]
        return $found[$idx]
      }
    }
    if ($choice -match '^(?i)g$') {
      $cloned = Clone-DuendeeTo $desktop
      if ($cloned) { return $cloned }
    }
    if ($choice -match '^(?i)b$') {
      $picked = Select-FolderBrowser 'Duendee proje klasörünü seçin'
      if ($picked -and (Test-Path -LiteralPath $picked -PathType Container)) {
        if (Test-LooksLikeDuendeeRepo $picked) { Update-DuendeeRepoSafe $picked }
        return (Resolve-Path -LiteralPath $picked).Path
      }
    }
    # fall through to custom path prompt
  } else {
    Write-UiLine "  $YEL   Yerel Duendee bulunamadı.$RST"
    Write-UiLine "  $DIM   Enter = Desktop'a klonla ($desktop\$($script:DuendeeCloneName))$RST"
    Write-UiLine "  $DIM   C = özel klasör yolu | B = klasör seçici | yol yaz = o dizine klonla/kullan$RST"
    Write-Ui '  seçim> '
    $choice = (Read-Host).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match '^(?i)g$') {
      $cloned = Clone-DuendeeTo $desktop
      if ($cloned) { return $cloned }
    } elseif ($choice -match '^(?i)b$') {
      $picked = Select-FolderBrowser 'Duendee proje klasörünü seçin (veya klon ana klasörü)'
      if ($picked) {
        if (Test-LooksLikeDuendeeRepo $picked) {
          Update-DuendeeRepoSafe $picked
          return (Resolve-Path -LiteralPath $picked).Path
        }
        $cloned = Clone-DuendeeTo $picked
        if ($cloned) { return $cloned }
      }
    } elseif ($choice -notmatch '^(?i)c$') {
      if (Test-Path -LiteralPath $choice -PathType Container) {
        if (Test-LooksLikeDuendeeRepo $choice) {
          Update-DuendeeRepoSafe $choice
          return (Resolve-Path -LiteralPath $choice).Path
        }
        $cloned = Clone-DuendeeTo $choice
        if ($cloned) { return $cloned }
      }
    }
  }

  while ($true) {
    Write-UiLine "  $DIM   Özel yol: mevcut Duendee klasörü veya klon ana dizini (boş = Desktop)$RST"
    Write-Ui '  projectPath> '
    $entered = (Read-Host).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $desktop }
    if ($entered -match '^(?i)b$') {
      $picked = Select-FolderBrowser 'Duendee proje klasörünü seçin'
      if (-not $picked) { continue }
      $entered = $picked
    }
    if (Test-Path -LiteralPath $entered -PathType Container) {
      if (Test-LooksLikeDuendeeRepo $entered) {
        Update-DuendeeRepoSafe $entered
        return (Resolve-Path -LiteralPath $entered).Path
      }
      # Parent dir: clone into it
      $maybeChild = Join-Path $entered $script:DuendeeCloneName
      if (Test-LooksLikeDuendeeRepo $maybeChild) {
        Update-DuendeeRepoSafe $maybeChild
        return (Resolve-Path -LiteralPath $maybeChild).Path
      }
      $cloned = Clone-DuendeeTo $entered
      if ($cloned) { return $cloned }
      Write-UiLine "  $YEL   Bu klasör Duendee değil ve klon başarısız.$RST"
      continue
    }
    Write-UiLine "  $YEL   Klasör bulunamadı: $entered$RST"
  }
}

function Ensure-ToolConfig {
  if (-not (Test-Path -LiteralPath $configPath)) {
    if (-not (Test-Path -LiteralPath $configExample)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST config.example.json bulunamadı. Portable paket bozuk olabilir."
      Pause-Enter
      exit 1
    }
    Copy-Item -LiteralPath $configExample -Destination $configPath -Force
    Write-UiLine "  $GRN   config.json oluşturuldu (config.example.json kopyası).$RST"
    Write-UiLine ''
  }

  try {
    $cfgLocal = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-UiLine "  $RED$BOLD[HATA]$RST config.json okunamadı: $($_.Exception.Message)"
    Pause-Enter
    exit 1
  }

  $proj = [string]$cfgLocal.projectPath
  $portNum = if ($cfgLocal.port) { [int]$cfgLocal.port } else { 8080 }
  if ($env:DT_DUENDEE_DIR -and (Test-Path -LiteralPath $env:DT_DUENDEE_DIR -PathType Container)) {
    $proj = (Resolve-Path -LiteralPath $env:DT_DUENDEE_DIR).Path
  }
  $placeholder = [string]::IsNullOrWhiteSpace($proj) -or
    $proj -match '[\\/]path[\\/]to[\\/]your[\\/]app' -or
    -not (Test-Path -LiteralPath $proj)

  if ($placeholder) {
    $proj = Resolve-ProjectPathInteractive -CurrentProj $proj
    Write-Ui "  port [$portNum]> "
    $portIn = (Read-Host).Trim()
    if ($portIn -match '^\d+$') { $portNum = [int]$portIn }
    Save-ToolConfig -ProjectPath $proj -PortNum $portNum
    Write-UiLine "  $GRN   Kaydedildi: $configPath$RST"
    Write-UiLine "  $GRN   projectPath = $proj$RST"
    Write-UiLine ''
  } elseif (Test-LooksLikeDuendeeRepo $proj) {
    Update-DuendeeRepoSafe $proj
  }

  return @{ Project = $proj; Port = $portNum }
}

function Test-UninstallAction([string]$Name) {
  return $Name -match '^(?i)(7|uninstall|kaldir|kaldır|remove)$'
}

$script:UninstallCli = Test-UninstallAction $Action
if ($script:UninstallCli) {
  $Project = ''
  $Port = 8080
} else {
  $boot = Ensure-ToolConfig
  $Project = [string]$boot.Project
  $Port = [int]$boot.Port
}

$StateDir = Join-Path $Root '.tunnelstate'
$PidFile = Join-Path $StateDir 'tunnel.pid'
$UrlFile = Join-Path $StateDir 'tunnel.url'
$LogFile = Join-Path $StateDir 'tunnel.log'
$OutLogFile = Join-Path $StateDir 'tunnel.out.log'
$ServerPidFile = Join-Path $StateDir 'server.pid'
if (-not $script:UninstallCli -and -not (Test-Path -LiteralPath $StateDir)) {
  New-Item -ItemType Directory -Path $StateDir | Out-Null
}

$script:BootTunnel = ($Action -eq 'boot-tunnel')
$script:AutoMode = -not [string]::IsNullOrWhiteSpace($Action) -and -not $script:BootTunnel
$env:PROJECT = $Project
$env:SERVER_PID = $ServerPidFile
$env:PID_FILE = $PidFile
$env:URL_FILE = $UrlFile
$env:LOG = $LogFile
$env:OUT_LOG = $OutLogFile

function Get-AutoRunCommand {
  $prop = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue
  if (-not $prop) { return '' }
  return [string]$prop.DuendeeTunnelTool
}

function Get-AutoMode {
  $cmd = Get-AutoRunCommand
  if ([string]::IsNullOrWhiteSpace($cmd)) { return 'off' }
  if ($cmd -match '(?i)boot-tunnel') { return 'tunnel' }
  return 'tool'
}

function Get-StableLaunchDir {
  Join-Path $env:LOCALAPPDATA 'DuendeeTunnel'
}

function Install-StableLauncher {
  $dir = Get-StableLaunchDir
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $src = Join-Path $OsDir 'stable-launch.ps1'
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src -Destination (Join-Path $dir 'launch.ps1') -Force
  }
  $cmd = Join-Path $dir 'launch.cmd'
  @(
    '@echo off',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*'
  ) -join "`r`n" | Set-Content -LiteralPath $cmd -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $dir 'root.txt') -Value (Get-NormalizedDir $Root) -Encoding ASCII

  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  if (Test-Path -LiteralPath $windowsApps) {
    @(
      '@echo off',
      'call "%LOCALAPPDATA%\DuendeeTunnel\launch.cmd" %*'
    ) -join "`r`n" | Set-Content -LiteralPath (Join-Path $windowsApps 'duendee-tunnel.cmd') -Encoding ASCII
  }

  try {
    $lnkPath = Join-Path (Get-UserDesktopPath) 'Duendee Tunnel Tool.lnk'
    $w = New-Object -ComObject WScript.Shell
    $sc = $w.CreateShortcut($lnkPath)
    $sc.TargetPath = $cmd
    $sc.WorkingDirectory = $dir
    $sc.Arguments = ''
    $ico = Join-Path $OsDir 'Duendee Tunnel Logo.ico'
    if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico }
    $sc.Description = 'Duendee Tunnel Tool'
    $sc.Save()
  } catch {}

  if ((Get-AutoMode) -ne 'off') {
    $mode = Get-AutoMode
    $val = '"' + $cmd + '"'
    if ($mode -eq 'tunnel') { $val = $val + ' boot-tunnel' }
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -Value $val -PropertyType String -Force | Out-Null
  }
}

function Set-AutoMode([string]$Mode) {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  if ($Mode -eq 'off') {
    Remove-ItemProperty -Path $key -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue
    return ((Get-AutoMode) -eq 'off')
  }
  Install-StableLauncher
  $cmd = Join-Path (Get-StableLaunchDir) 'launch.cmd'
  $val = '"' + $cmd + '"'
  if ($Mode -eq 'tunnel') { $val = $val + ' boot-tunnel' }
  New-ItemProperty -Path $key -Name 'DuendeeTunnelTool' -Value $val -PropertyType String -Force | Out-Null
  return ((Get-AutoMode) -eq $Mode)
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
  # TcpClient is much faster than Get-NetTCPConnection on Windows
  try {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $iar = $tcp.BeginConnect('127.0.0.1', $PortNum, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(120) -and $tcp.Connected) {
      try { $tcp.EndConnect($iar) } catch {}
      $tcp.Close()
      return $true
    }
    $tcp.Close()
  } catch {}
  return $false
}

function Find-NodeExe {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $localNode = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\node') -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($localNode) { return $localNode.FullName }
  foreach ($c in @(
      (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
      $(if ($pf86) { Join-Path $pf86 'nodejs\node.exe' } else { $null }),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

function Ensure-WhatsAppDeps {
  $marker = Join-Path $Root 'node_modules\@whiskeysockets\baileys\package.json'
  if (Test-Path -LiteralPath $marker) { return $true }
  if (-not ((Get-Command npm.cmd -ErrorAction SilentlyContinue) -or (Get-Command npm -ErrorAction SilentlyContinue))) {
    return $false
  }
  Write-UiLine "  $DIM   WhatsApp bağımlılıkları kuruluyor (npm install)...$RST"
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  try {
    Push-Location $Root
    try {
      & cmd.exe /c "npm.cmd install --omit=dev"
      if ($LASTEXITCODE -ne 0) { & cmd.exe /c "npm.cmd install" }
    } finally { Pop-Location }
  } finally {
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
  }
  return (Test-Path -LiteralPath $marker)
}

function Send-TunnelWhatsApp([string]$PublicUrl) {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $waCfg = Join-Path $Root 'scripts\whatsapp-config.json'
  if (-not (Test-Path -LiteralPath $waJs)) {
    Write-UiLine "  $YEL   WhatsApp scripti yok: $waJs$RST"
    return
  }
  $node = Find-NodeExe
  if (-not $node) {
    Write-UiLine "  $YEL   node bulunamadı — WhatsApp gönderilemedi. Node.js kurup tekrar deneyin.$RST"
    return
  }
  if (-not (Ensure-WhatsAppDeps)) {
    Write-UiLine "  $YEL   WhatsApp paketleri eksik. Kurulum: cd `"$Root`" && npm install$RST"
    return
  }
  if ([string]::IsNullOrWhiteSpace($PublicUrl) -or $PublicUrl -notmatch '^https://') {
    Write-UiLine "  $YEL   Geçerli tünel URL'si yok; WhatsApp atlandı.$RST"
    return
  }
  $phone = ''
  if (Test-Path -LiteralPath $waCfg) {
    try {
      $wc = Get-Content -LiteralPath $waCfg -Raw -Encoding UTF8 | ConvertFrom-Json
      $phone = [string]$wc.targetPhone
    } catch {}
  }
  $sessionCreds = Join-Path $Root '.whatsapp-session\creds.json'
  $line = if ($phone) { $phone } else { '5315162429' }
  if (-not (Test-Path -LiteralPath $sessionCreds)) {
    Write-UiLine "  $YEL   WhatsApp hatti $line bagli degil. Yeni QR olusturuluyor.$RST"
    Write-UiLine "  $DIM   WhatsApp > Bagli Cihazlar > Cihaz Bagla. Tarama sonrasi link gider.$RST"
  } else {
    Write-UiLine "  WhatsApp hatti kontrol ediliyor ($line)..."
  }
  Write-UiLine "  WhatsApp'a link gönderiliyor..."
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  try {
    # Avoid PowerShell mangling leading '+' on phone; pass via env instead
    $env:DT_WA_PHONE = $phone
    $env:DT_WA_URL = $PublicUrl
    & $node $waJs $PublicUrl $phone
    $ec = $LASTEXITCODE
    if ($ec -ne 0) {
      Write-UiLine "  $YEL   WhatsApp gönderimi başarısız (çıkış $ec).$RST"
      Write-UiLine "  $DIM   QR tarayin veya oturumu sifirlayip tekrar deneyin:$RST"
      Write-UiLine "  $DIM   Remove-Item -Recurse -Force `"$Root\.whatsapp-session`"$RST"
      Write-UiLine "  $DIM   Manuel: node `"$waJs`" `"$PublicUrl`"$RST"
    } else {
      Write-UiLine "  $GRN   WhatsApp mesaji gonderildi.$RST"
    }
  } finally {
    Remove-Item Env:DT_WA_PHONE -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
  }
}

function Invoke-RetractWhatsApp {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $sentFile = Join-Path $Root '.whatsapp-session\sent-links.json'
  $sessionCreds = Join-Path $Root '.whatsapp-session\creds.json'
  if (-not (Test-Path -LiteralPath $waJs) -or -not (Test-Path -LiteralPath $sentFile) -or -not (Test-Path -LiteralPath $sessionCreds)) {
    return
  }
  $raw = Get-Content -LiteralPath $sentFile -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq '[]') { return }
  $node = Find-NodeExe
  if (-not $node) { return }
  if (-not (Ensure-WhatsAppDeps)) { return }
  Write-UiLine "  Eski tunnel linki mesajlari kaldiriliyor..."
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  try {
    $env:DT_WA_ACTION = 'retract'
    if (-not $env:DT_WA_TIMEOUT_MS) { $env:DT_WA_TIMEOUT_MS = '45000' }
    & $node $waJs
    if ($LASTEXITCODE -ne 0) {
      Write-UiLine "  $YEL   Eski WhatsApp link mesaji kaldirilamadi (çıkış $LASTEXITCODE).$RST"
    } else {
      Write-UiLine "  $GRN   Gecersiz tunnel linki mesaji kaldirildi.$RST"
    }
  } finally {
    Remove-Item Env:DT_WA_ACTION -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_TIMEOUT_MS -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
  }
}

function Install-UserNode {
  if (Find-NodeExe) {
    $bin = Split-Path -Parent (Find-NodeExe)
    if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
    return $true
  }
  $ver = 'v22.14.0'
  $zip = Join-Path $env:TEMP "node-$ver-win-x64.zip"
  $dest = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\node'
  Write-UiLine "  Node.js kuruluyor ($ver, hesap gerekmez)..."
  try {
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip" -OutFile $zip -UseBasicParsing
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
  } catch {
    Write-UiLine "  $YEL   Node.js indirilemedi.$RST"
    return $false
  }
  $node = Find-NodeExe
  if (-not $node) { return $false }
  $bin = Split-Path -Parent $node
  if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
  return $true
}

function Install-UserCloudflared {
  $existing = Find-Cloudflared
  if ($existing) { return $true }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
  $destDir = Join-Path $env:USERPROFILE '.cloudflared'
  $dest = Join-Path $destDir 'cloudflared.exe'
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  Write-UiLine "  cloudflared kuruluyor (hesap gerekmez)..."
  try {
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$arch.exe" -OutFile $dest -UseBasicParsing
  } catch {
    Write-UiLine "  $YEL   cloudflared indirilemedi.$RST"
    return $false
  }
  return (Test-Path -LiteralPath $dest)
}

function Ensure-RuntimeRequirements {
  [void](Install-UserNode)
  [void](Install-UserCloudflared)
  [void](Ensure-WhatsAppDeps)
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

function Start-DetachedCommand([string]$CommandLine) {
  try {
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine }
    return ($result.ReturnValue -eq 0)
  } catch {
    return $false
  }
}

function Start-HiddenDetached([string]$CommandLine) {
  $vbs = Join-Path $env:TEMP ("duendee-hidden-" + [guid]::NewGuid().ToString('n') + '.vbs')
  $escaped = $CommandLine.Replace('"', '""')
  $line = 'CreateObject("Wscript.Shell").Run "' + $escaped + '", 0, False'
  [System.IO.File]::WriteAllText($vbs, $line)
  return Start-DetachedCommand -CommandLine "wscript.exe //B //Nologo `"$vbs`""
}

function Start-HiddenCmd([string]$Command) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
  # /S keeps a quoted exe path intact. Without it cmd strips the first and last quote and exits at once.
  $psi.Arguments = '/D /S /C "' + $Command + '"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  return [System.Diagnostics.Process]::Start($psi)
}

function Start-DetachedRetract {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $sentFile = Join-Path $Root '.whatsapp-session\sent-links.json'
  $sessionCreds = Join-Path $Root '.whatsapp-session\creds.json'
  if (-not (Test-Path -LiteralPath $waJs) -or -not (Test-Path -LiteralPath $sentFile) -or -not (Test-Path -LiteralPath $sessionCreds)) {
    return
  }
  $raw = Get-Content -LiteralPath $sentFile -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq '[]') { return }
  $node = Find-NodeExe
  if (-not $node) { return }
  [void](Start-HiddenDetached -CommandLine "`"$node`" `"$waJs`" --retract")
}

function Start-ToolWatcher {
  $watcher = Join-Path $OsDir 'scripts\tunnel-watcher.ps1'
  if (-not (Test-Path -LiteralPath $watcher)) { return }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $projectArg = ($Project -replace '"', '\"')
  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcher`" -ToolPid $PID -Project `"$projectArg`" -ToolRoot `"$Root`""
  # Hidden and outside this console, so no second terminal appears and closing the window does not kill it.
  if (Start-HiddenDetached -CommandLine "`"$ps`" $arg") { return }
  Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $watcher, '-ToolPid', "$PID", '-Project', $Project, '-ToolRoot', $Root
  ) | Out-Null
}

function Invoke-ExtractUrl {
  $extract = Join-Path $OsDir 'scripts\extract-tunnel-url.ps1'
  if (-not (Test-Path -LiteralPath $extract)) { return }
  # In-process — avoid flashing a second PowerShell window
  & $extract -Log $LogFile -OutLog $OutLogFile -UrlFile $UrlFile | Out-Null
}

function Stop-ProcessTree([int]$ProcessId) {
  if ($ProcessId -le 0) { return }
  # /T kills the whole tree (cmd -> npm -> node/vite, etc.)
  & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
  try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-DevServer {
  $stopped = $false
  if (Test-Path -LiteralPath $ServerPidFile) {
    $spidRaw = Get-Content -LiteralPath $ServerPidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $spid = 0
    if ([int]::TryParse("$spidRaw".Trim(), [ref]$spid) -and $spid -gt 0) {
      if (Test-PidAlive $spid) {
        Stop-ProcessTree $spid
        $stopped = $true
        Write-UiLine "  $GRN   Dev server durduruldu - PID $spid.$RST"
      }
    }
    Remove-Item -LiteralPath $ServerPidFile -Force -ErrorAction SilentlyContinue
  }
  # Fallback: kill hidden cmd/npm trees started for this project
  if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $devPattern = "*cd /d $Project*"
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like $devPattern } |
      ForEach-Object {
        Stop-ProcessTree ([int]$_.ProcessId)
        $stopped = $true
      }
  }
  if (-not $stopped) {
    Write-UiLine "  $DIM   Dev server zaten kapalı.$RST"
  }
}

function Get-TunnelUrl {
  Invoke-ExtractUrl
  if (-not (Test-Path -LiteralPath $UrlFile)) { return $null }
  $u = (Get-Content -LiteralPath $UrlFile -Raw -ErrorAction SilentlyContinue)
  if ([string]::IsNullOrWhiteSpace($u)) { return $null }
  return $u.Trim()
}

function Format-ShortLogLine([string]$Line) {
  $t = $Line -replace '^\d{4}-\d{2}-\d{2}T\S+\s+', ''
  $t = $t -replace '^(ERR|WRN|INF)\s+', ''
  if ($t -match 'Registered tunnel connection') { return 'Tünel bağlandı' }
  if ($t -match 'quick Tunnel has been created|Requesting new quick Tunnel') { return 'Hızlı tünel açıldı' }
  if ($t -match 'Unable to reach the origin|connection refused') { return 'Yerel sunucuya ulaşılamadı' }
  if ($t -match 'failed to serve tunnel|connection terminated|context canceled') { return 'Tünel kesildi' }
  if ($t -match '^\+|^\||Thank you for trying|no uptime guarantee|Cannot determine default|GOOS:|GoArch:|Settings:|automatically update|Generated Connector|Initial protocol|ICMP proxy|metrics server|^Version ') {
    return $null
  }
  $t = $t.Trim()
  if (-not $t) { return $null }
  if ($t.Length -gt 64) { return $t.Substring(0, 61) + '...' }
  return $t
}

function Show-LogTail {
  param([switch]$Brief)
  Write-UiLine "  $DIM   Son log:$RST"
  if (-not (Test-Path -LiteralPath $LogFile)) { return }
  if ($Brief) {
    $shown = New-Object System.Collections.Generic.List[string]
    foreach ($s in (Get-Content -LiteralPath $LogFile -Tail 24 -ErrorAction SilentlyContinue)) {
      $short = Format-ShortLogLine $s
      if (-not $short) { continue }
      if ($shown.Contains($short)) { continue }
      [void]$shown.Add($short)
    }
    $start = [Math]::Max(0, $shown.Count - 4)
    for ($i = $start; $i -lt $shown.Count; $i++) {
      Write-UiLine "    $($shown[$i])"
    }
    return
  }
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
    Stop-ProcessTree $tpid
    Write-UiLine "  $GRN   Tünel durduruldu - PID $tpid.$RST"
  }
  Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
}

function Stop-TunnelAndDevServer {
  # Used by [4] cancel — stop tunnel + the tool-started dev server
  if (Test-TunnelRunning) {
    Stop-TunnelOnly
  } else {
    Write-UiLine "  $YEL   Aktif tünel servisi yok.$RST"
    Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
    Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  }
  Stop-DevServer
}

function Stop-AllToolProcesses {
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Stop-ProcessTree $tpid
    Write-UiLine "  $GRN   Tünel servisi durduruldu - PID $tpid.$RST"
  } elseif ($tpid) {
    Write-UiLine "  $DIM   PID $tpid zaten çalışmıyor.$RST"
  } else {
    Write-UiLine "  $YEL   Tanımlı çalışan tünel servisi yok.$RST"
  }
  Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
  Stop-DevServer
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  Get-Process PhotosApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'duendee-whatsapp-qr.png') -Force -ErrorAction SilentlyContinue
}

function Show-Logo {
  # FIGlet "ANSI Shadow" — same layered block style as Claude Code
  $rows = @(
    '██████╗ ██╗   ██╗███████╗███╗   ██╗██████╗ ███████╗███████╗',
    '██╔══██╗██║   ██║██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝',
    '██║  ██║██║   ██║█████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ',
    '██║  ██║██║   ██║██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ',
    '██████╔╝╚██████╔╝███████╗██║ ╚████║██████╔╝███████╗███████╗',
    '╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚══════╝'
  )
  Write-UiLine ''
  foreach ($r in $rows) {
    Write-UiLine ("$SALMON$BOLD  $r$RST")
  }
  Write-UiLine ''
  Write-UiLine "$DIM   ───────────────────────────────────────────────────────────$RST"
  Write-UiLine "$SKY$BOLD          D U E N D E E   T U N N E L   T O O L$RST"
  Write-UiLine "$DIM   ───────────────────────────────────────────────────────────$RST"
  Write-UiLine ''
}

function Show-Menu {
  Initialize-Utf8Console
  Clear-Host
  $autoMode = Get-AutoMode
  Show-Logo
  Write-UiLine "  $YEL$BOLD[1]$RST  ${SKY}Tünel Servisi Başlat$RST"
  Write-UiLine "  $YEL$BOLD[2]$RST  ${SKY}Servis Durumunu Kontrol Et$RST"
  Write-UiLine "  $YEL$BOLD[3]$RST  ${SKY}Yayın Linkini Kopyala$RST"
  Write-UiLine "  $YEL$BOLD[4]$RST  ${SKY}Tünel Servisini İptal Et$RST"
  Write-UiLine "  $YEL$BOLD[5]$RST  ${SKY}Tüm Terminalleri Kapat ve Çık$RST"
  $autoLabel = switch ($autoMode) {
    'tool' { "$GRN[TOOL]$RST" }
    'tunnel' { "$GRN[TOOL+TÜNEL]$RST" }
    default { "$DIM[KAPALI]$RST" }
  }
  Write-UiLine "  $YEL$BOLD[6]$RST  ${SKY}Cihaz Açılışında Otomatik Başlat$RST  $autoLabel"
  Write-UiLine "  $YEL$BOLD[7]$RST  ${SKY}Aracı Cihazdan Kaldır$RST"
  Write-UiLine ''
  Write-UiLine "$DIM      Kapatmak için pencereyi kapatın, [Ctrl]+[C] ya da [5]$RST"
  Write-UiLine ''
  Write-Ui "$CYN   Seçim [1-7]: $RST"
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
  if (Test-Path -LiteralPath $LogFile) { Show-LogTail -Brief }
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
    $serverOut = Join-Path $StateDir 'server.out.log'
    $serverErr = Join-Path $StateDir 'server.err.log'
    $p = Start-HiddenCmd "cd /d `"$Project`" & npm run dev > `"$serverOut`" 2> `"$serverErr`""
    if ($p) { Set-Content -LiteralPath $ServerPidFile -Value $p.Id -Encoding Ascii }
    $ready = $false
    for ($i = 1; $i -le 80; $i++) {
      if (Test-PortListening $Port) { $ready = $true; break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $ready) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Dev server $Port portunda açılamadı."
      Write-UiLine "  $DIM   npm run dev çıktısını ayrı bir pencerede deneyin.$RST"
      Complete-Action
      return
    }
    Write-UiLine "  ${CYN}[2/4]$RST Dev server http://127.0.0.1:$Port hazır."
  } else {
    Write-UiLine "  ${CYN}[2/4]$RST Dev server $Port portunda hazır."
  }

  Write-UiLine "  ${CYN}[3/4]$RST Cloudflare tünel başlatılıyor..."
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $UrlFile, $LogFile, $OutLogFile -Force -ErrorAction SilentlyContinue
  # 127.0.0.1 + IPv4 edge avoids localhost/IPv6 happy-eyeballs delay on Windows
  $target = "http://127.0.0.1:$Port"
  $cfCmd = "`"$cf`" tunnel --url `"$target`" --no-autoupdate --protocol http2 --edge-ip-version 4 --retries 3 > `"$OutLogFile`" 2> `"$LogFile`""
  $tp = Start-HiddenCmd $cfCmd
  if (-not $tp) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel başlatılamadı. Log: $LogFile"
    Complete-Action
    return
  }
  Set-Content -LiteralPath $PidFile -Value $tp.Id -Encoding Ascii
  Start-Sleep -Milliseconds 300
  if (-not (Test-PidAlive $tp.Id)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel açılır açılmaz çıktı. Son log:"
    Show-LogTail
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  Write-UiLine "  ${CYN}[4/4]$RST Yayın linki bekleniyor..."
  $url = $null
  $waitStart = [datetime]::UtcNow
  $deadline = $waitStart.AddSeconds(45)
  $tick = 0
  while ([datetime]::UtcNow -lt $deadline) {
    $tick++
    $url = Get-TunnelUrl
    if ($url) { break }
    if (-not (Test-PidAlive $tp.Id)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Tünel çıktı, link alınamadı. Son log:"
      Show-LogTail
      Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
      Complete-Action
      return
    }
    if (($tick % 20) -eq 0) {
      $sec = [int]([datetime]::UtcNow - $waitStart).TotalSeconds
      Write-UiLine "  $DIM   ... $sec saniye beklendi$RST"
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $url) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Yayın linki alınamadı - süre doldu. Son log:"
    Show-LogTail
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  # Origin port was already verified; one quick HTTP check is enough
  if (-not (Test-PortListening $Port)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Dev server origin $Port portunda yanıt vermiyor."
    Show-LogTail
    Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
    Complete-Action
    return
  }

  $pub = '000'
  $pubOk = $false
  for ($tries = 1; $tries -le 2; $tries++) {
    $url = Get-TunnelUrl
    try { $pub = & curl.exe -s -o nul -w '%{http_code}' --max-time 3 $url } catch { $pub = '000' }
    if (-not $pub) { $pub = '000' }
    $n = 0
    if ([int]::TryParse("$pub", [ref]$n) -and $n -ge 200 -and $n -le 399) {
      Write-UiLine "  $GRN   Yayın adresi erişilebilir, kod: $pub - yayın hazır.$RST"
      $pubOk = $true
      break
    }
    Start-Sleep -Milliseconds 400
  }
  if (-not $pubOk) {
    Write-UiLine "  $YEL   Uyarı: halka açık adres henüz doğrulanamadı, son kod: $pub.$RST"
    Write-UiLine "  $DIM   Cloudflare yönlendirmesi birkaç saniye içinde hazır olur.$RST"
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
    Send-TunnelWhatsApp -PublicUrl $url
  }
  Complete-Action
}

function Invoke-Cancel {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Tünel servisini iptal et ---$RST"
  Write-UiLine ''
  $hadTunnel = Test-TunnelRunning
  $hadServer = $false
  if (Test-Path -LiteralPath $ServerPidFile) {
    $spidRaw = Get-Content -LiteralPath $ServerPidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $spid = 0
    if ([int]::TryParse("$spidRaw".Trim(), [ref]$spid) -and (Test-PidAlive $spid)) { $hadServer = $true }
  }
  if (-not $hadTunnel -and -not $hadServer) {
    Write-UiLine "  $YEL   Aktif tünel servisi yok.$RST"
    Write-UiLine "  $DIM   İptal edilecek bir şey yok. Başlatmak için menüden [1] kullanın.$RST"
    Complete-Action
    return
  }
  Stop-TunnelAndDevServer
  Invoke-RetractWhatsApp
  Write-UiLine "  $GRN   Tünel ve dev server iptal edildi. Yeni tünel otomatik başlatılmadı.$RST"
  Complete-Action
}

function Invoke-Autostart {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Cihaz Açılışında Otomatik Başlat ---$RST"
  Write-UiLine ''
  $mode = Get-AutoMode
  switch ($mode) {
    'tool' {
      Write-UiLine "  $DIM   Durum:$RST $GRN$BOLD[TOOL]$RST"
      Write-UiLine "  $DIM   Cihaz açıldığında yalnızca tool açılır. Tünel servisini [1] ile başlatırsın.$RST"
    }
    'tunnel' {
      Write-UiLine "  $DIM   Durum:$RST $GRN$BOLD[TOOL+TÜNEL]$RST"
      Write-UiLine "  $DIM   Cihaz açıldığında tool açılır ve tünel servisi kendiliğinden başlar.$RST"
    }
    default {
      Write-UiLine "  $DIM   Durum:$RST $RED$BOLD[KAPALI]$RST"
      Write-UiLine "  $DIM   Cihaz açıldığında tool açılmıyor.$RST"
    }
  }
  Write-UiLine ''
  Write-UiLine "  $YEL$BOLD[T]$RST  ${SKY}Yalnızca tool'u otomatik başlat$RST"
  Write-UiLine "  $YEL$BOLD[S]$RST  ${SKY}Tool'u ve tünel servisini otomatik başlat$RST"
  if ($mode -ne 'off') {
    Write-UiLine "  $YEL$BOLD[K]$RST  ${SKY}Otomatik başlatmayı kapat$RST"
  }
  Write-UiLine "  $YEL$BOLD[X]$RST  ${SKY}Geri dön$RST"
  Write-UiLine ''
  $choices = if ($mode -ne 'off') { 'TSKX' } else { 'TSX' }
  Write-Ui "$CYN   Seçim: $RST"
  $c = Get-Choice $choices
  Write-UiLine ''
  if ($c -eq 'X') { return }
  $target = switch ($c) {
    'T' { 'tool' }
    'S' { 'tunnel' }
    default { 'off' }
  }
  if ($target -eq $mode) {
    Write-UiLine "  $YEL   Bu ayar zaten seçili.$RST"
    Complete-Action
    return
  }
  $ok = Set-AutoMode $target
  if ($ok) {
    switch ($target) {
      'tool' { Write-UiLine "  $GRN   Yalnızca tool otomatik başlayacak.$RST" }
      'tunnel' { Write-UiLine "  $GRN   Tool ve tünel servisi otomatik başlayacak.$RST" }
      default { Write-UiLine "  $GRN   Otomatik başlatma kapatıldı.$RST" }
    }
    Write-UiLine "  $DIM   Kayıt: HKCU\...\Run - DuendeeTunnelTool$RST"
  } else {
    Write-UiLine "  $RED$BOLD[HATA]$RST Ayar kaydedilemedi."
  }
  Complete-Action
}

function Get-NormalizedDir([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $Path.TrimEnd('\') }
}

function Get-ToolInstallDir {
  if ($env:DT_INSTALL_DIR -and (Test-Path -LiteralPath $env:DT_INSTALL_DIR)) {
    return (Get-NormalizedDir $env:DT_INSTALL_DIR)
  }
  return (Get-NormalizedDir (Join-Path $env:LOCALAPPDATA 'DuendeeTunnelTool'))
}

function Get-RegisteredProducts([string]$Pattern) {
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  $found = @()
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($item in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
      $prop = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
      if ($prop -and $prop.DisplayName -and ($prop.DisplayName -match $Pattern)) {
        $found += $prop
      }
    }
  }
  return $found
}

function Invoke-ProductUninstall($Entry) {
  $cmd = [string]$Entry.QuietUninstallString
  if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = [string]$Entry.UninstallString }
  $cmd = $cmd.Trim()
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
  if ($cmd -match '(?i)msiexec(\.exe)?' -and $cmd -match '\{[0-9A-Fa-f-]+\}') {
    $guid = $Matches[0]
    $proc = Start-Process -FilePath msiexec.exe -ArgumentList @('/x', $guid, '/qn', '/norestart') -Wait -PassThru
    return ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010)
  }
  $exe = $null
  $arg = ''
  if ($cmd.StartsWith('"')) {
    $end = $cmd.IndexOf('"', 1)
    if ($end -lt 2) { return $false }
    $exe = $cmd.Substring(1, $end - 1)
    $arg = $cmd.Substring($end + 1).Trim()
  } else {
    $parts = $cmd -split '\s+', 2
    $exe = $parts[0]
    if ($parts.Length -gt 1) { $arg = $parts[1] }
  }
  if (-not (Test-Path -LiteralPath $exe) -and -not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $false }
  if ($arg -notmatch '(?i)(/quiet|/qn|/silent|--silent|/VERYSILENT)') {
    if ($exe -match '(?i)unins\d*\.exe|uninstall\.exe') {
      $arg = ("$arg /VERYSILENT /NORESTART").Trim()
    }
  }
  $proc = Start-Process -FilePath $exe -ArgumentList $arg -Wait -PassThru
  return ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010)
}

function Invoke-WingetIdUninstall([string[]]$Ids) {
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue) -and -not (Get-Command winget -ErrorAction SilentlyContinue)) {
    return
  }
  foreach ($id in $Ids) {
    & winget uninstall --id $id -e --silent --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
  }
}

function Remove-KnownCloudflaredBinary {
  $candidates = @()
  $found = Find-Cloudflared
  if ($found) { $candidates += $found }
  $candidates += @(
    'C:\Program Files (x86)\cloudflared\cloudflared.exe',
    (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
    (Join-Path $env:USERPROFILE '.cloudflared\cloudflared.exe')
  )
  foreach ($path in ($candidates | Select-Object -Unique)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
    if ((Split-Path -Leaf $path) -ne 'cloudflared.exe') { continue }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $path
    $leaf = Split-Path -Leaf $parent
    if ($leaf -eq 'cloudflared') {
      $left = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)
      if ($left.Count -eq 0) {
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Remove-UserPathEntry([string]$BinDir) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { return }
  $target = (Get-NormalizedDir $BinDir)
  $kept = @($userPath -split ';' | Where-Object {
      $_ -and ((Get-NormalizedDir $_.Trim()) -ne $target)
    })
  [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
}

function Get-AncestorProcessIds {
  $ids = New-Object 'System.Collections.Generic.HashSet[int]'
  $cur = [int]$PID
  while ($cur -gt 0 -and $ids.Add($cur)) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $cur = [int]$proc.ParentProcessId
  }
  return $ids
}

function Stop-OtherToolProcesses([string]$ToolRoot) {
  $keep = Get-AncestorProcessIds
  $root = $ToolRoot.TrimEnd('\')
  if (-not $root) { return }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    -not $keep.Contains([int]$_.ProcessId) -and $_.CommandLine -and ($_.CommandLine -like "*$root*")
  } | ForEach-Object { Stop-ProcessTree ([int]$_.ProcessId) }
}

function Start-DeferredDirectoryDelete {
  param([string[]]$Paths)
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $id = [guid]::NewGuid().ToString('N')
  $list = Join-Path $env:TEMP ("duendee-uninstall-" + $id + '.txt')
  $clean = @($Paths | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
  [System.IO.File]::WriteAllLines($list, $clean, $utf8)
  $runner = [System.IO.Path]::ChangeExtension($list, '.ps1')
  $body = @'
param([string]$ListFile)
Set-Location -LiteralPath $env:TEMP
$deadline = (Get-Date).AddSeconds(30)
do {
  $pending = New-Object System.Collections.Generic.List[string]
  if (Test-Path -LiteralPath $ListFile) {
    foreach ($raw in [System.IO.File]::ReadAllLines($ListFile)) {
      $p = "$raw".Trim().TrimStart([char]0xFEFF)
      if (-not $p) { continue }
      if (-not (Test-Path -LiteralPath $p)) { continue }
      try {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
      } catch {
        cmd.exe /c "rmdir /s /q `"$p`"" | Out-Null
      }
      if (Test-Path -LiteralPath $p) { [void]$pending.Add($p) }
    }
  }
  if ($pending.Count -eq 0) { break }
  [System.IO.File]::WriteAllLines($ListFile, $pending.ToArray())
  Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)
Remove-Item -LiteralPath $ListFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
  [System.IO.File]::WriteAllText($runner, $body.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8)
  Set-Location -LiteralPath $env:TEMP
  Start-Process -FilePath powershell.exe -WorkingDirectory $env:TEMP -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-ListFile', $list
  ) | Out-Null
}

function Invoke-RemoveDependencies {
  $nodeProducts = @(Get-RegisteredProducts '(?i)^Node\.js')
  $cfProducts = @(Get-RegisteredProducts '(?i)cloudflared')
  foreach ($entry in @($nodeProducts + $cfProducts)) {
    $name = [string]$entry.DisplayName
    Write-UiLine "  $DIM   Kaldırılıyor: $name$RST"
    if (Invoke-ProductUninstall $entry) {
      Write-UiLine "  $GRN   $name kaldırıldı.$RST"
    } else {
      Write-UiLine "  $YEL   $name kaldırılamadı. Yönetici onayı gerekebilir.$RST"
    }
  }
  if (Get-Command node -ErrorAction SilentlyContinue) {
    Invoke-WingetIdUninstall @(
      'OpenJS.NodeJS.LTS',
      'OpenJS.NodeJS'
    )
  }
  if (Get-Command cloudflared -ErrorAction SilentlyContinue) {
    Invoke-WingetIdUninstall @('Cloudflare.cloudflared')
  }
  Remove-KnownCloudflaredBinary
  if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    Write-UiLine "  $YEL   Node.js hâlâ duruyor: $($nodeCmd.Source)$RST"
    Write-UiLine "  $DIM   Yönetici PowerShell ile tekrar deneyin veya Windows Ayarlar > Uygulamalar üzerinden kaldırın.$RST"
  } else {
    Write-UiLine "  $GRN   Node.js bu oturumda artık yok.$RST"
  }
  if (Find-Cloudflared) {
    Write-UiLine "  $YEL   cloudflared hâlâ duruyor: $(Find-Cloudflared)$RST"
  } else {
    Write-UiLine "  $GRN   cloudflared bu oturumda artık yok.$RST"
  }
}

function Get-UninstallLines([string]$Mode) {
  $lines = New-Object System.Collections.Generic.List[string]
  $install = Get-ToolInstallDir
  $rootFull = Get-NormalizedDir $Root
  $seen = @{}
  foreach ($dir in @($install, $rootFull)) {
    if (-not $dir -or $seen.ContainsKey($dir.ToLowerInvariant())) { continue }
    $seen[$dir.ToLowerInvariant()] = $true
    if (Test-Path -LiteralPath $dir) { [void]$lines.Add("Tool klasörü: $dir") }
  }
  $bin = Join-Path $install 'bin'
  [void]$lines.Add("Komut ve kullanıcı PATH kaydı: $bin")
  $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\duendee-tunnel.cmd'
  if (Test-Path -LiteralPath $wa) { [void]$lines.Add("Komut: $wa") }
  $lnk = Join-Path (Get-UserDesktopPath) 'Duendee Tunnel Tool.lnk'
  if (Test-Path -LiteralPath $lnk) { [void]$lines.Add("Masaüstü kısayolu: $lnk") }
  $stable = Get-StableLaunchDir
  if (Test-Path -LiteralPath $stable) { [void]$lines.Add("Sabit başlatıcı: $stable") }
  [void]$lines.Add('Açılış kaydı: HKCU\...\Run\DuendeeTunnelTool')
  if ($Mode -eq '2') {
    [void]$lines.Add('Node.js (bu cihazdaki kurulum; diğer programlar da etkilenir)')
    [void]$lines.Add('cloudflared (bu cihazdaki kurulum)')
  }
  return $lines
}

function Invoke-Uninstall {
  param([string]$Mode = '')
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Aracı Kaldır ---$RST"
  Write-UiLine ''
  if ($Mode -notin @('1', '2')) {
    Write-UiLine "  $YEL$BOLD[1]$RST  ${SKY}Yalnızca Duendee Tunnel Tool$RST"
    Write-UiLine "  $DIM      Kurulum, komut, PATH, kısayol ve otomatik başlatma silinir.$RST"
    Write-UiLine "  $YEL$BOLD[2]$RST  ${SKY}Tool ile birlikte Node.js ve cloudflared$RST"
    Write-UiLine "  $DIM      [1] ile aynı, artı bu cihazdaki Node.js ve cloudflared.$RST"
    Write-UiLine "  $YEL$BOLD[X]$RST  ${SKY}Vazgeç$RST"
    Write-UiLine ''
    Write-Ui "$CYN   Seçim [1/2/X]: $RST"
    $pick = Get-Choice '12X'
    Write-UiLine $pick
    if ($pick -eq 'X') { return }
    $Mode = $pick
  }

  Write-UiLine ''
  Write-UiLine "  $RED$BOLD   Emin misiniz?$RST Bu işlem geri alınamaz."
  Write-UiLine ''
  foreach ($line in (Get-UninstallLines $Mode)) {
    Write-UiLine "  $DIM   - $line$RST"
  }
  Write-UiLine ''
  Write-Ui "$CYN   [E] Evet, kaldır    [H] Hayır: $RST"
  $yes = Get-Choice 'EH'
  Write-UiLine $yes
  if ($yes -ne 'E') {
    Write-UiLine ''
    Write-UiLine "  $YEL   Kaldırma iptal edildi.$RST"
    if (-not $script:UninstallCli) { Complete-Action }
    return
  }

  Write-UiLine ''
  Invoke-RetractWhatsApp
  $script:CleanupDone = $true
  Stop-AllToolProcesses
  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue

  $install = Get-ToolInstallDir
  $rootFull = Get-NormalizedDir $Root
  Remove-UserPathEntry (Join-Path $install 'bin')
  Remove-UserPathEntry (Join-Path $rootFull 'bin')
  $waShim = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\duendee-tunnel.cmd'
  Remove-Item -LiteralPath $waShim -Force -ErrorAction SilentlyContinue
  $lnk = Join-Path (Get-UserDesktopPath) 'Duendee Tunnel Tool.lnk'
  Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
  $stableDir = Get-StableLaunchDir

  if ($Mode -eq '2') {
    Invoke-RemoveDependencies
  }

  Stop-OtherToolProcesses $rootFull
  $scriptFull = Get-NormalizedDir $PSCommandPath
  $immediate = @()
  $deferred = @()
  $seen = @{}
  foreach ($dir in @($install, $rootFull, (Get-NormalizedDir $stableDir))) {
    if (-not $dir -or $seen.ContainsKey($dir.ToLowerInvariant())) { continue }
    $seen[$dir.ToLowerInvariant()] = $true
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $dirPrefix = $dir.TrimEnd('\') + '\'
    if ($scriptFull.StartsWith($dirPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or ($scriptFull -eq $dir)) {
      $deferred += $dir
    } else {
      $immediate += $dir
    }
  }
  foreach ($dir in $immediate) {
    try {
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
      Write-UiLine "  $GRN   Silindi: $dir$RST"
    } catch {
      $deferred += $dir
    }
  }
  if ($deferred.Count -gt 0) {
    Start-DeferredDirectoryDelete -Paths $deferred
    foreach ($dir in $deferred) {
      Write-UiLine "  $GRN   Silinecek (bu pencere kapanınca): $dir$RST"
    }
  }
  Write-UiLine ''
  Write-UiLine "  $GRN   Kaldırma tamam.$RST"
  Write-UiLine ''
  exit 0
}

function Invoke-Shutdown {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$CYN   --- Tüm terminaller kapatılıyor ---$RST"
  Invoke-RetractWhatsApp
  Stop-AllToolProcesses
  Write-UiLine "  $GRN   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...$RST"
  Write-UiLine ''
  exit 0
}

# Quiet cleanup when the main console is closed or Ctrl+C ends the process.
# If this process is killed with the window, the watcher deletes the WhatsApp link.
$script:CleanupDone = $false
function Invoke-ExitCleanup {
  if ($script:CleanupDone) { return }
  $script:CleanupDone = $true
  try {
    # Spawn before any slow process cleanup. Closing the window kills this process quickly.
    Start-DetachedRetract
    $tpid = Read-TunnelPid
    if ($tpid -and (Test-PidAlive $tpid)) { Stop-ProcessTree $tpid }
    Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
    if (Test-Path -LiteralPath $ServerPidFile) {
      $spidRaw = Get-Content -LiteralPath $ServerPidFile -TotalCount 1 -ErrorAction SilentlyContinue
      $spid = 0
      if ([int]::TryParse("$spidRaw".Trim(), [ref]$spid) -and $spid -gt 0) { Stop-ProcessTree $spid }
      Remove-Item -LiteralPath $ServerPidFile -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
      $devPattern = "*cd /d $Project*"
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like $devPattern } |
        ForEach-Object { Stop-ProcessTree ([int]$_.ProcessId) }
    }
    Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  } catch {}
}

try {
  if (-not ('DuendeeConsoleCtrl' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DuendeeConsoleCtrl {
  public delegate bool Handler(int ctrlType);
  [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(Handler handler, bool add);
}
'@
  }
  $script:ConsoleCloseHandler = [DuendeeConsoleCtrl+Handler] {
    param([int]$ctrlType)
    # 2 = window closed. Start the delete before this process is torn down.
    if ($ctrlType -eq 2) { Start-DetachedRetract }
    return $false
  }
  [void][DuendeeConsoleCtrl]::SetConsoleCtrlHandler($script:ConsoleCloseHandler, $true)
} catch {}

try {
  [Console]::TreatControlCAsInput = $false
  $null = [Console]::add_CancelKeyPress({
      param($sender, $e)
      $e.Cancel = $true
      Invoke-ExitCleanup
      [Environment]::Exit(0)
    })
} catch {}

if (-not $script:UninstallCli) {
  try { Install-StableLauncher } catch {}
  Start-ToolWatcher
}

try {
  if ($script:UninstallCli) {
    $script:CleanupDone = $true
    Invoke-Uninstall -Mode $UninstallChoice
    exit 0
  }
  Ensure-RuntimeRequirements
  if ($script:BootTunnel) {
    Invoke-Start
  }
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
    $choice = Get-Choice '1234567'
    Write-UiLine ''
    try {
      switch ($choice) {
        '1' { Invoke-Start }
        '2' { Invoke-Status }
        '3' { Invoke-CopyLink }
        '4' { Invoke-Cancel }
        '5' { Invoke-Shutdown }
        '6' { Invoke-Autostart }
        '7' { Invoke-Uninstall }
      }
    } catch {
      Write-UiLine "  $RED$BOLD[HATA]$RST $($_.Exception.Message)"
      Complete-Action
    }
  }
} finally {
  # Window close / normal exit path — watcher covers hard kills
  Invoke-ExitCleanup
}

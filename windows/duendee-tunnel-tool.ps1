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
# Claude Code–style warm salmon for DuendeeFM / root banner
$SALMON = "$Esc[38;2;232;113;90m"
# Purple for Duendee (Duendee-main / neo) banner
$PURPLE = "$Esc[38;2;167;139;250m"
# One hue per menu action. Detail stays dim. Red is only for errors.
$C1 = "$Esc[96m"
$C2 = "$Esc[38;2;96;165;250m"
$C3 = "$Esc[38;2;125;211;252m"
$C4 = "$Esc[38;2;251;146;60m"
$C5 = "$Esc[38;2;167;139;250m"
$C6 = "$Esc[38;2;251;113;133m"

$configPath = Join-Path $Root 'config.json'
$configExample = Join-Path $Root 'config.example.json'
# Always Duendee-FM — Duendee.git is the main product and must never overwrite FM branding.
$script:DuendeeRepoUrl = if ($env:DT_DUENDEE_REPO_URL) { $env:DT_DUENDEE_REPO_URL } else { 'https://github.com/hayripenah/Duendee-FM.git' }
$script:DuendeeCloneName = if ($env:DT_DUENDEE_CLONE_NAME) { $env:DT_DUENDEE_CLONE_NAME } else { 'Duendee-fm' }
$script:LastMobileApkSent = $false

function Save-ToolConfig(
  [string]$ProjectPath,
  [int]$PortNum,
  [string]$AppPath = '',
  [string]$DuendeeProjectPath = '',
  [int]$DuendeePortNum = 0,
  [string]$DuendeeBranch = ''
) {
  $prev = $null
  if (Test-Path -LiteralPath $configPath) {
    try { $prev = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $obj = [ordered]@{ projectPath = $ProjectPath; port = $PortNum }
  if (-not [string]::IsNullOrWhiteSpace($AppPath)) {
    $obj.appPath = $AppPath
  } elseif ($prev -and $prev.appPath) {
    $obj.appPath = [string]$prev.appPath
  }
  $duoPath = if (-not [string]::IsNullOrWhiteSpace($DuendeeProjectPath)) { $DuendeeProjectPath }
    elseif ($prev -and $prev.duendeeProjectPath) { [string]$prev.duendeeProjectPath } else { '' }
  $duoPort = if ($DuendeePortNum -gt 0) { $DuendeePortNum }
    elseif ($prev -and $prev.duendeePort) { [int]$prev.duendeePort } else { 8081 }
  $duoBranch = if (-not [string]::IsNullOrWhiteSpace($DuendeeBranch)) { $DuendeeBranch }
    elseif ($prev -and $prev.duendeeBranch) { [string]$prev.duendeeBranch } else { 'neo-3d' }
  if (-not [string]::IsNullOrWhiteSpace($duoPath)) { $obj.duendeeProjectPath = $duoPath }
  $obj.duendeePort = $duoPort
  $obj.duendeeBranch = $duoBranch
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

function Test-IsDuendeeMainPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  return ((Split-Path -Leaf $Path) -match '^(?i)duendee-main$')
}

function Test-LooksLikeNeoDuendeeRepo([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $pkg = Join-Path $Path 'package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return $false }
  $leaf = Split-Path -Leaf $Path
  $nameHit = $leaf -match '^(?i)duendee(-main)?$'
  $pkgHit = $false
  try {
    $raw = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8
    if ($raw -match 'vite_react_shadcn' -or $raw -match 'dev:tunnel' -or
        ($raw -match '"dev"\s*:\s*"vite"' -and $nameHit)) { $pkgHit = $true }
  } catch {}
  $remoteHit = $false
  if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
    try {
      $remote = (& git -C $Path remote get-url origin 2>$null)
      # Duendee.git / Duendee-main — not Duendee-FM, not Tunnel-Tool.
      if ($remote -and (
          $remote -match '(?i)github\.com[:/].*hayripenah/Duendee(\.git)?/?$' -or
          $remote -match '(?i)/Duendee-main(\.git)?/?$' -or
          ($remote -match '(?i)/Duendee(\.git)?/?$' -and $remote -notmatch '(?i)(Duendee-FM|Tunnel-Tool|Duendee-app)')
        )) {
        $remoteHit = $true
      }
    } catch {}
  }
  return ($remoteHit -or (Test-IsDuendeeMainPath $Path -and $pkgHit) -or ($nameHit -and $pkgHit))
}

function Find-LocalNeoDuendeeRepos {
  $desktop = Get-UserDesktopPath
  $candidates = New-Object System.Collections.Generic.List[string]
  $add = {
    param([string]$p)
    if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) {
      try {
        $full = (Resolve-Path -LiteralPath $p).Path
        if (-not $candidates.Contains($full)) { [void]$candidates.Add($full) }
      } catch {}
    }
  }
  if ($env:DT_NEO_DUENDEE_DIR) { & $add $env:DT_NEO_DUENDEE_DIR }
  & $add (Join-Path (Split-Path -Parent $Root) 'Duendee-main')
  foreach ($base in @(
      $desktop,
      (Join-Path $desktop 'YEK\Cursor'),
      (Join-Path $env:USERPROFILE 'YEK\Cursor'),
      (Join-Path $env:USERPROFILE 'Desktop\YEK\Cursor')
    )) {
    if (-not $base) { continue }
    foreach ($name in @('Duendee-main', 'Duendee')) { & $add (Join-Path $base $name) }
  }
  $hits = @()
  foreach ($c in $candidates) {
    if (Test-LooksLikeNeoDuendeeRepo $c) { $hits += $c }
  }
  return $hits
}

function Test-LooksLikeDuendeeRepo([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  # DuendeeFM section publishes Duendee-fm only. Never treat Duendee-main as the FM app tree.
  if (Test-IsDuendeeMainPath $Path) { return $false }
  $leaf = Split-Path -Leaf $Path
  $nameHit = $leaf -match '^(?i)duendee(-fm)?$'
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
      # Accept only Duendee-FM (not Duendee.git / Duendee-main / Tunnel-Tool).
      if ($remote -and ($remote -match '(?i)github\.com[:/].*hayripenah/Duendee-FM(\.git)?/?$' -or
          ($remote -match '(?i)/Duendee-FM(\.git)?/?$' -and $remote -notmatch '(?i)Tunnel-Tool'))) {
        $remoteHit = $true
      }
    } catch {}
  }
  return ($remoteHit -or ($nameHit -and $pkgHit) -or ($pkgHit -and (Test-Path -LiteralPath $gitDir)))
}

function Test-LooksLikeDuendeeApp([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  $pkg = Join-Path $Path 'package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return $false }
  try {
    $raw = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8
    if ($raw -match '"name"\s*:\s*"duendee-app"' -or $raw -match 'Capacitor \+ Electron') { return $true }
  } catch {}
  return (
    (Test-Path -LiteralPath (Join-Path $Path 'electron')) -and
    (Test-Path -LiteralPath (Join-Path $Path 'capacitor.config.json'))
  )
}

function Resolve-DuendeeAppPath([string]$Preferred = '', [string]$Project = '') {
  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(
      $Preferred,
      $env:DT_DUENDEE_APP_DIR,
      (Join-Path (Split-Path -Parent $Root) 'Duendee-app'),
      $(if ($Project) { Join-Path (Split-Path -Parent $Project) 'Duendee-app' } else { '' }),
      (Join-Path (Get-UserDesktopPath) 'Duendee-app')
    )) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
    try { [void]$candidates.Add((Resolve-Path -LiteralPath $p).Path) } catch {}
  }
  foreach ($c in $candidates) {
    if (Test-LooksLikeDuendeeApp $c) { return $c }
  }
  return ''
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

function Restore-DuendeeKept([string]$Path, [string]$KeepRoot) {
  foreach ($item in @('.env', '.env.local', 'node_modules')) {
    $saved = Join-Path $KeepRoot $item
    if (-not (Test-Path -LiteralPath $saved)) { continue }
    $dest = Join-Path $Path $item
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $saved -Destination $dest -Force -ErrorAction SilentlyContinue
  }
}

function Update-DuendeeSnapshot([string]$Path) {
  $stageParent = Join-Path $env:TEMP ("duendee-upd-" + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $stageParent | Out-Null
  $stage = Join-Path $stageParent 'src'
  if (-not (Save-PublicGitHubTree -RepoUrl $script:DuendeeRepoUrl -Target $stage)) {
    Remove-Item -LiteralPath $stageParent -Recurse -Force -ErrorAction SilentlyContinue
    Write-UiLine "  $YEL   Duendee güncellenemedi.$RST"
    return $false
  }
  $keepRoot = Join-Path $stageParent 'keep'
  New-Item -ItemType Directory -Force -Path $keepRoot | Out-Null
  foreach ($item in @('.env', '.env.local', 'node_modules')) {
    $src = Join-Path $Path $item
    if (Test-Path -LiteralPath $src) {
      Move-Item -LiteralPath $src -Destination (Join-Path $keepRoot $item) -Force
    }
  }
  Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  $stageNames = @(Get-ChildItem -LiteralPath $stage -Force | ForEach-Object { $_.Name })
  $landed = $true
  Get-ChildItem -LiteralPath $stage -Force | ForEach-Object {
    $dest = Join-Path $Path $_.Name
    if (Test-Path -LiteralPath $dest) {
      Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $dest) { $landed = $false; return }
    try {
      Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop
    } catch {
      $landed = $false
    }
  }
  $stale = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ne '.git' -and $stageNames -notcontains $_.Name
  })
  Restore-DuendeeKept -Path $Path -KeepRoot $keepRoot
  Remove-Item -LiteralPath $stageParent -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $landed -or $stale.Count -gt 0 -or -not (Test-Path -LiteralPath (Join-Path $Path 'package.json'))) {
    Write-UiLine "  $YEL   Duendee güncellenemedi.$RST"
    return $false
  }
  Write-UiLine "  $DIM   Repo güncel.$RST"
  return $true
}

function Invoke-DuendeeGit([string]$RepoPath, [string[]]$Cred, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & git @Cred -C $RepoPath @GitArgs 2>&1
    return [int]$LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-DuendeeGitRev([string]$RepoPath, [string[]]$Cred, [string]$Rev) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $text = & git @Cred -C $RepoPath rev-parse $Rev 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ("$text").Trim()
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Update-DuendeeFromGit([string]$Path, [string[]]$Cred, [string]$Remote) {
  foreach ($branch in @('main', 'master')) {
    $fetched = (Invoke-DuendeeGit $Path $Cred @('fetch', '--depth', '1', $Remote, $branch)) -eq 0
    if (-not $fetched) {
      $fetched = (Invoke-DuendeeGit $Path $Cred @('fetch', $Remote, $branch)) -eq 0
    }
    if (-not $fetched) { continue }
    # `git fetch <remote> <branch>` updates FETCH_HEAD. It does not move refs/remotes/origin/<branch>.
    if ((Invoke-DuendeeGit $Path $Cred @('reset', '--hard', 'FETCH_HEAD')) -ne 0) { continue }
    $head = Get-DuendeeGitRev $Path $Cred 'HEAD'
    $tip = Get-DuendeeGitRev $Path $Cred 'FETCH_HEAD'
    if ($head -and $head -eq $tip) {
      [void](Invoke-DuendeeGit $Path $Cred @('update-ref', "refs/remotes/origin/$branch", $tip))
      return $true
    }
  }
  return $false
}

function Update-DuendeeRepoSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  Write-UiLine "  $DIM   Duendee güncelleniyor...$RST"
  $gitOk = $false
  if ((Test-Path -LiteralPath (Join-Path $Path '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    try {
      $env:GIT_TERMINAL_PROMPT = '0'
      $gh = Get-Command gh -ErrorAction SilentlyContinue
      $cred = @('-c', 'credential.helper=')
      if ($gh) {
        & $gh.Source auth status 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) { $cred = @('-c', 'credential.helper=!gh auth git-credential') }
      }
      # Prefer the folder's own origin when it already points at Duendee-FM.
      $originUrl = ''
      try { $originUrl = [string](& git -C $Path remote get-url origin 2>$null) } catch {}
      if ($originUrl -match '(?i)Duendee-FM') {
        $gitOk = [bool](Update-DuendeeFromGit -Path $Path -Cred $cred -Remote 'origin')
      }
      if (-not $gitOk) {
        $gitOk = [bool](Update-DuendeeFromGit -Path $Path -Cred $cred -Remote $script:DuendeeRepoUrl)
      }
      if (-not $gitOk) {
        $gitOk = [bool](Update-DuendeeFromGit -Path $Path -Cred $cred -Remote 'origin')
      }
    } catch {}
  }
  if ($gitOk) {
    Write-UiLine "  $DIM   Repo güncel.$RST"
    return $true
  }
  return [bool](Update-DuendeeSnapshot -Path $Path)
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
  & $add (Join-Path (Split-Path -Parent $Root) 'Duendee-fm')
  foreach ($base in @($desktop, $userHome, $docs, (Join-Path $userHome 'YEK\Cursor'), (Join-Path $desktop 'YEK\Cursor'), (Join-Path $userHome 'Cursor'), (Join-Path $desktop 'Cursor'))) {
    if (-not $base) { continue }
    foreach ($name in @('Duendee-fm', 'Duendee', 'duendee-fm', 'duendee')) {
      & $add (Join-Path $base $name)
    }
  }
  foreach ($scanRoot in @($desktop, $docs, $userHome, (Join-Path $userHome 'YEK'), (Join-Path $desktop 'YEK'))) {
    if (-not $scanRoot -or -not (Test-Path -LiteralPath $scanRoot)) { continue }
    try {
      Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(?i)duendee(-fm)?$'
      } | ForEach-Object { & $add $_.FullName }
      Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cursor = Join-Path $_.FullName 'Cursor'
        if (Test-Path -LiteralPath $cursor) {
          Get-ChildItem -LiteralPath $cursor -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(?i)duendee(-fm)?$'
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
      $null = Update-DuendeeRepoSafe $target
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
    Write-UiLine "  $DIM   Enter=[1]  numara  C=yol  B=klasör  G=klonla$RST"
    Write-Ui '  seçim> '
    $choice = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') {
      $path = $found[0]
      $null = Update-DuendeeRepoSafe $path
      return $path
    }
    if ($choice -match '^\d+$') {
      $idx = [int]$choice - 1
      if ($idx -ge 0 -and $idx -lt $found.Count) {
        $null = Update-DuendeeRepoSafe $found[$idx]
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
        if (Test-LooksLikeDuendeeRepo $picked) { $null = Update-DuendeeRepoSafe $picked }
        return (Resolve-Path -LiteralPath $picked).Path
      }
    }
    # fall through to custom path prompt
  } else {
    Write-UiLine "  $YEL   Yerel Duendee bulunamadı.$RST"
    Write-UiLine "  $DIM   Enter = Desktop'a klonla$RST"
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
          $null = Update-DuendeeRepoSafe $picked
          return (Resolve-Path -LiteralPath $picked).Path
        }
        $cloned = Clone-DuendeeTo $picked
        if ($cloned) { return $cloned }
      }
    } elseif ($choice -notmatch '^(?i)c$') {
      if (Test-Path -LiteralPath $choice -PathType Container) {
        if (Test-LooksLikeDuendeeRepo $choice) {
          $null = Update-DuendeeRepoSafe $choice
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
        $null = Update-DuendeeRepoSafe $entered
        return (Resolve-Path -LiteralPath $entered).Path
      }
      # Parent dir: clone into it
      $maybeChild = Join-Path $entered $script:DuendeeCloneName
      if (Test-LooksLikeDuendeeRepo $maybeChild) {
        $null = Update-DuendeeRepoSafe $maybeChild
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
  $appPath = [string]$cfgLocal.appPath
  $portNum = if ($cfgLocal.port) { [int]$cfgLocal.port } else { 8080 }
  if ($env:DT_DUENDEE_DIR -and (Test-Path -LiteralPath $env:DT_DUENDEE_DIR -PathType Container)) {
    $proj = (Resolve-Path -LiteralPath $env:DT_DUENDEE_DIR).Path
  }
  if ($env:DT_DUENDEE_APP_DIR -and (Test-Path -LiteralPath $env:DT_DUENDEE_APP_DIR -PathType Container)) {
    $appPath = (Resolve-Path -LiteralPath $env:DT_DUENDEE_APP_DIR).Path
  }
  $placeholder = [string]::IsNullOrWhiteSpace($proj) -or
    $proj -match '[\\/]path[\\/]to[\\/]your[\\/]app' -or
    $proj -match '[\\/]path[\\/]to[\\/]Duendee-fm' -or
    (Test-IsDuendeeMainPath $proj) -or
    -not (Test-Path -LiteralPath $proj)

  if ($placeholder) {
    $proj = Resolve-ProjectPathInteractive -CurrentProj $proj
    Write-Ui "  port [$portNum]> "
    $portIn = (Read-Host).Trim()
    if ($portIn -match '^\d+$') { $portNum = [int]$portIn }
    $appPath = Resolve-DuendeeAppPath -Preferred $appPath -Project $proj
    Save-ToolConfig -ProjectPath $proj -PortNum $portNum -AppPath $appPath
    Write-UiLine "  $GRN   Kaydedildi: $configPath$RST"
    Write-UiLine "  $GRN   projectPath = $proj$RST"
    if ($appPath) { Write-UiLine "  $GRN   appPath = $appPath$RST" }
    Write-UiLine ''
  } elseif (Test-LooksLikeDuendeeRepo $proj) {
    $null = Update-DuendeeRepoSafe $proj
  }
  if ([string]::IsNullOrWhiteSpace($appPath) -or -not (Test-Path -LiteralPath $appPath -PathType Container)) {
    $appPath = Resolve-DuendeeAppPath -Preferred $appPath -Project $proj
  }

  $duoProj = [string]$cfgLocal.duendeeProjectPath
  $duoPort = if ($cfgLocal.duendeePort) { [int]$cfgLocal.duendeePort } else { 8081 }
  $duoBranch = if ($cfgLocal.duendeeBranch) { [string]$cfgLocal.duendeeBranch } else { 'neo-3d' }
  if ($env:DT_NEO_DUENDEE_DIR -and (Test-Path -LiteralPath $env:DT_NEO_DUENDEE_DIR -PathType Container)) {
    $duoProj = (Resolve-Path -LiteralPath $env:DT_NEO_DUENDEE_DIR).Path
  }
  $duoPlaceholder = [string]::IsNullOrWhiteSpace($duoProj) -or
    -not (Test-Path -LiteralPath $duoProj) -or
    -not (Test-LooksLikeNeoDuendeeRepo $duoProj)
  if ($duoPlaceholder) {
    $foundNeo = @(Find-LocalNeoDuendeeRepos)
    if ($foundNeo.Count -gt 0) {
      $duoProj = $foundNeo[0]
      Write-UiLine "  $GRN   Duendee (neo) projectPath = $duoProj$RST"
    }
  }
  Save-ToolConfig -ProjectPath $proj -PortNum $portNum -AppPath $appPath `
    -DuendeeProjectPath $duoProj -DuendeePortNum $duoPort -DuendeeBranch $duoBranch

  return @{
    Project = $proj
    Port = $portNum
    AppPath = $appPath
    DuendeeProject = $duoProj
    DuendeePort = $duoPort
    DuendeeBranch = $duoBranch
  }
}

function Test-UninstallAction([string]$Name) {
  return $Name -match '^(?i)(6|uninstall|kaldir|kaldır|remove)$'
}

$script:UninstallCli = Test-UninstallAction $Action
if ($script:UninstallCli) {
  $Project = ''
  $Port = 8080
  $AppPath = ''
} else {
  $boot = Ensure-ToolConfig
  $Project = [string]$boot.Project
  $Port = [int]$boot.Port
  $AppPath = [string]$boot.AppPath
  $script:FmProject = $Project
  $script:FmPort = $Port
  $script:FmAppPath = $AppPath
  $script:DuendeeProject = [string]$boot.DuendeeProject
  $script:DuendeePort = [int]$boot.DuendeePort
  $script:DuendeeBranch = if ($boot.DuendeeBranch) { [string]$boot.DuendeeBranch } else { 'neo-3d' }
}

$script:ActiveProduct = 'fm'
$script:FmStateDir = Join-Path $Root '.tunnelstate'
$script:DuendeeStateDir = Join-Path $Root '.tunnelstate-duendee'

function Bind-ProductState {
  param([ValidateSet('fm', 'duendee')][string]$Product)
  $script:ActiveProduct = $Product
  if ($Product -eq 'duendee') {
    $script:Project = $script:DuendeeProject
    $script:Port = $script:DuendeePort
    $script:AppPath = ''
    $script:StateDir = $script:DuendeeStateDir
  } else {
    $script:Project = $script:FmProject
    $script:Port = $script:FmPort
    $script:AppPath = $script:FmAppPath
    $script:StateDir = $script:FmStateDir
  }
  # Locals used throughout the script (not only $script:*)
  $script:ProjectRef = $script:Project
  Set-Variable -Name Project -Scope Script -Value $script:Project
  Set-Variable -Name Port -Scope Script -Value $script:Port
  Set-Variable -Name AppPath -Scope Script -Value $script:AppPath
  Set-Variable -Name StateDir -Scope Script -Value $script:StateDir
  Set-Variable -Name PidFile -Scope Script -Value (Join-Path $script:StateDir 'tunnel.pid')
  Set-Variable -Name UrlFile -Scope Script -Value (Join-Path $script:StateDir 'tunnel.url')
  Set-Variable -Name LogFile -Scope Script -Value (Join-Path $script:StateDir 'tunnel.log')
  Set-Variable -Name OutLogFile -Scope Script -Value (Join-Path $script:StateDir 'tunnel.out.log')
  Set-Variable -Name ServerPidFile -Scope Script -Value (Join-Path $script:StateDir 'server.pid')
  Set-Variable -Name DesktopAppPidFile -Scope Script -Value (Join-Path $script:StateDir 'desktop-app.pid')
  if (-not $script:UninstallCli -and -not (Test-Path -LiteralPath $script:StateDir)) {
    New-Item -ItemType Directory -Path $script:StateDir | Out-Null
  }
  $env:PROJECT = $script:Project
  $env:SERVER_PID = (Join-Path $script:StateDir 'server.pid')
  $env:PID_FILE = (Join-Path $script:StateDir 'tunnel.pid')
  $env:URL_FILE = (Join-Path $script:StateDir 'tunnel.url')
  $env:LOG = (Join-Path $script:StateDir 'tunnel.log')
  $env:OUT_LOG = (Join-Path $script:StateDir 'tunnel.out.log')
  $env:DT_PRODUCT = $Product
}

# Default: DuendeeFM context (autostart / CLI actions stay on FM)
if ($script:UninstallCli) {
  $StateDir = $script:FmStateDir
  $PidFile = Join-Path $StateDir 'tunnel.pid'
  $UrlFile = Join-Path $StateDir 'tunnel.url'
  $LogFile = Join-Path $StateDir 'tunnel.log'
  $OutLogFile = Join-Path $StateDir 'tunnel.out.log'
  $ServerPidFile = Join-Path $StateDir 'server.pid'
  $DesktopAppPidFile = Join-Path $StateDir 'desktop-app.pid'
} else {
  Bind-ProductState 'fm'
}

$script:BootTunnel = ($Action -eq 'boot-tunnel')
$script:RecoverTunnel = ($Action -eq 'recover-tunnel')
$script:AutoMode = -not [string]::IsNullOrWhiteSpace($Action) -and -not $script:BootTunnel
if ($script:RecoverTunnel) {
  # Helpers below are not defined yet — keep product-tagged recover copy inline.
  if ($script:ActiveProduct -eq 'duendee') {
    $env:DT_WA_TEMPLATE = "Duendee tüneli yenilendi (main)`n{url}"
    $env:DT_WA_PRODUCT = 'duendee'
  } else {
    $env:DT_WA_TEMPLATE = "DuendeeFM tüneli yenilendi`n{url}"
    $env:DT_WA_PRODUCT = 'fm'
  }
  $env:DT_RECOVER = '1'
}

function Get-AutoRunCommand {
  $prop = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue
  if (-not $prop) { return '' }
  return [string]$prop.DuendeeTunnelTool
}

function Get-StartupShortcutPath {
  Join-Path ([Environment]::GetFolderPath('Startup')) 'Duendee Tunnel Tool.lnk'
}

function Get-AutoMode {
  $lnk = Get-StartupShortcutPath
  if (Test-Path -LiteralPath $lnk) {
    try {
      $w = New-Object -ComObject WScript.Shell
      $sc = $w.CreateShortcut($lnk)
      if ([string]$sc.Arguments -match '(?i)boot-tunnel') { return 'tunnel' }
      return 'tool'
    } catch {}
  }
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
    Set-StartupShortcut (Get-AutoMode)
  }
}

function Set-StartupShortcut([string]$Mode) {
  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue
  $lnk = Get-StartupShortcutPath
  if ($Mode -eq 'off') {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    return
  }
  $dir = Get-StableLaunchDir
  $launch = Join-Path $dir 'launch.cmd'
  $w = New-Object -ComObject WScript.Shell
  $sc = $w.CreateShortcut($lnk)
  $sc.TargetPath = $launch
  $sc.WorkingDirectory = $dir
  $sc.Arguments = $(if ($Mode -eq 'tunnel') { 'boot-tunnel' } else { '' })
  $sc.WindowStyle = 1
  $ico = Join-Path $OsDir 'Duendee Tunnel Logo.ico'
  if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico }
  $sc.Description = 'Duendee Tunnel Tool'
  $sc.Save()
}

function Set-AutoMode([string]$Mode) {
  if ($Mode -eq 'off') {
    Set-StartupShortcut 'off'
    return ((Get-AutoMode) -eq 'off')
  }
  Install-StableLauncher
  Set-StartupShortcut $Mode
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
  foreach ($hostName in @('127.0.0.1', '::1')) {
    try {
      $tcp = [System.Net.Sockets.TcpClient]::new()
      $iar = $tcp.BeginConnect($hostName, $PortNum, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) {
        try { $tcp.EndConnect($iar) } catch {}
        $tcp.Close()
        return $true
      }
      $tcp.Close()
    } catch {}
  }
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

function Get-WaSessionDir {
  Join-Path $env:LOCALAPPDATA 'DuendeeWhatsApp'
}

function Get-ProductDisplayName {
  if ($script:ActiveProduct -eq 'duendee') { return 'Duendee' }
  return 'DuendeeFM'
}

function Get-ProductWaTemplate {
  if ($script:ActiveProduct -eq 'duendee') {
    return "Duendee tüneli (main)`n{url}"
  }
  return "DuendeeFM tüneli`n{url}"
}

function Get-ProductWaRecoverTemplate {
  if ($script:ActiveProduct -eq 'duendee') {
    return "Duendee tüneli yenilendi (main)`n{url}"
  }
  return "DuendeeFM tüneli yenilendi`n{url}"
}

function Format-ProductTunnelLine([string]$Url) {
  $name = Get-ProductDisplayName
  if ([string]::IsNullOrWhiteSpace($Url)) { return "$name tüneli: (yok)" }
  return "$name tüneli: $Url"
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
  $phones = @()
  if (Test-Path -LiteralPath $waCfg) {
    try {
      $wc = Get-Content -LiteralPath $waCfg -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($wc.targetPhones) { $phones += @($wc.targetPhones) }
      if ($wc.targetPhone) { $phones += @($wc.targetPhone) }
    } catch {}
  }
  $phones = @($phones | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  $phone = ($phones -join ',')
  $productName = Get-ProductDisplayName
  $line = if ($phones.Count -gt 1) { "$($phones.Count) alici: $($phones -join ', ')" } elseif ($phone) { $phone } else { '5315162429' }
  Write-UiLine "  WhatsApp baglantisi kontrol ediliyor ($line)..."
  Write-UiLine "  WhatsApp'a $productName linki gönderiliyor..."
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
    $env:DT_WA_PRODUCT = if ($script:ActiveProduct -eq 'duendee') { 'duendee' } else { 'fm' }
    $env:DT_WA_TEMPLATE = Get-ProductWaTemplate
    $env:DT_WA_URL_FILE = $UrlFile
    & $node $waJs $PublicUrl $phone
    $ec = $LASTEXITCODE
    if ($ec -ne 0) {
      Write-UiLine "  $YEL   WhatsApp gönderimi başarısız (çıkış $ec).$RST"
      Write-UiLine "  $DIM   QR tarayin veya oturumu sifirlayip tekrar deneyin:$RST"
      Write-UiLine "  $DIM   Remove-Item -Recurse -Force `"$(Get-WaSessionDir)`"$RST"
      Write-UiLine "  $DIM   Manuel: node `"$waJs`" `"$PublicUrl`"$RST"
    } else {
      Write-UiLine "  $GRN   WhatsApp $productName mesaji gonderildi.$RST"
    }
  } finally {
    Remove-Item Env:DT_WA_PHONE -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_PRODUCT -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_TEMPLATE -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL_FILE -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
  }
}

function Invoke-RetractWhatsApp {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $sessionCreds = Join-Path (Get-WaSessionDir) 'creds.json'
  if (-not (Test-Path -LiteralPath $waJs) -or -not (Test-Path -LiteralPath $sessionCreds)) {
    return
  }
  $node = Find-NodeExe
  if (-not $node) { return }
  if (-not (Ensure-WhatsAppDeps)) { return }
  $productName = Get-ProductDisplayName
  Write-UiLine "  Eski $productName tunnel / APK WhatsApp mesajlari kaldiriliyor..."
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  try {
    $env:DT_WA_ACTION = 'retract'
    $env:DT_WA_PRODUCT = if ($script:ActiveProduct -eq 'duendee') { 'duendee' } else { 'fm' }
    $env:DT_WA_URL_FILE = $UrlFile
    if (-not $env:DT_WA_TIMEOUT_MS) { $env:DT_WA_TIMEOUT_MS = '90000' }
    & $node $waJs
    if ($LASTEXITCODE -ne 0) {
      Write-UiLine "  $YEL   Eski WhatsApp $productName mesaji kaldirilamadi (çıkış $LASTEXITCODE).$RST"
    } else {
      Write-UiLine "  $GRN   Gecersiz $productName tunnel / APK mesaji kaldirildi.$RST"
    }
  } finally {
    Remove-Item Env:DT_WA_ACTION -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_TIMEOUT_MS -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_PRODUCT -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL_FILE -ErrorAction SilentlyContinue
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

function Start-DetachedGuiWithEnv([string]$FileName, [string]$WorkingDirectory, [hashtable]$Environment) {
  # Same breakaway path as cloudflared: survive tool terminal close; [4] stops it.
  if ([string]::IsNullOrWhiteSpace($FileName) -or -not (Test-Path -LiteralPath $FileName)) { return $null }
  $wd = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path -Parent $FileName }
  $parts = New-Object System.Collections.Generic.List[string]
  if ($Environment) {
    foreach ($key in $Environment.Keys) {
      $val = [string]$Environment[$key]
      $val = $val.Replace("'", "''")
      [void]$parts.Add("`$env:$key='$val'")
    }
  }
  $exeLit = $FileName.Replace("'", "''")
  $wdLit = $wd.Replace("'", "''")
  [void]$parts.Add("Start-Process -FilePath '$exeLit' -WorkingDirectory '$wdLit'")
  $script = ($parts -join '; ')
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $launcher = Start-HiddenCmd "`"$ps`" -NoProfile -WindowStyle Hidden -EncodedCommand $b64"
  $deadline = [datetime]::UtcNow.AddSeconds(8)
  $leaf = [IO.Path]::GetFileNameWithoutExtension($FileName)
  while ([datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $hit = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $ep = [string]$_.ExecutablePath
        if ($ep -and ($ep -ieq $FileName)) { return $true }
        $n = [string]$_.Name
        return ($n -ieq "$leaf.exe")
      } |
      Select-Object -First 1
    if ($hit -and $hit.ProcessId) {
      return [int]$hit.ProcessId
    }
  }
  if ($launcher -and $launcher.Id) { return [int]$launcher.Id }
  return $null
}

$script:ToolJobHandle = [IntPtr]::Zero

function Initialize-ToolJob {
  if ($script:ToolJobHandle -ne [IntPtr]::Zero) { return }
  if (-not ('DuendeeToolJob' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DuendeeToolJob {
  [StructLayout(LayoutKind.Sequential)]
  struct BasicLimits {
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct IoCounters {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct ExtendedLimits {
    public BasicLimits Basic;
    public IoCounters Io;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr CreateJobObject(IntPtr attr, string name);
  [DllImport("kernel32.dll")]
  static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  public static IntPtr CreateKillOnCloseJob() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) return IntPtr.Zero;
    var limits = new ExtendedLimits();
    limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    int size = Marshal.SizeOf(typeof(ExtendedLimits));
    IntPtr mem = Marshal.AllocHGlobal(size);
    try {
      Marshal.StructureToPtr(limits, mem, false);
      if (!SetInformationJobObject(job, 9, mem, (uint)size)) return IntPtr.Zero;
    } finally {
      Marshal.FreeHGlobal(mem);
    }
    return job;
  }
}
'@
  }
  $script:ToolJobHandle = [DuendeeToolJob]::CreateKillOnCloseJob()
}

function Add-ProcessToToolJob([System.Diagnostics.Process]$Process) {
  if (-not $Process) { return }
  try {
    Initialize-ToolJob
    if ($script:ToolJobHandle -eq [IntPtr]::Zero) { return }
    [void][DuendeeToolJob]::AssignProcessToJobObject($script:ToolJobHandle, $Process.Handle)
  } catch {}
}

function Start-HiddenCmd([string]$Command) {
  # No console window. Break away from this terminal's job so closing the tool
  # does not tear down the tunnel or the app. [4] is what stops them.
  if (-not ('DuendeeHiddenProcess' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DuendeeHiddenProcess {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct PROCESS_INFORMATION {
    public IntPtr hProcess, hThread;
    public int dwProcessId, dwThreadId;
  }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  public static int Start(string commandLine) {
    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    PROCESS_INFORMATION pi;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    bool ok = CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB, IntPtr.Zero, null, ref si, out pi);
    if (!ok) {
      ok = CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, IntPtr.Zero, null, ref si, out pi);
    }
    if (!ok) return 0;
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return pi.dwProcessId;
  }
}
'@
  }
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $commandLine = '"' + $cmdExe + '" /D /S /C "' + $Command + '"'
  try {
    $procId = [DuendeeHiddenProcess]::Start($commandLine)
    if ($procId -gt 0) {
      $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if (-not $proc) {
        Start-Sleep -Milliseconds 200
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
      }
      if ($proc) { return $proc }
    }
  } catch {}
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cmdExe
  $psi.Arguments = '/D /S /C "' + $Command + '"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  return [System.Diagnostics.Process]::Start($psi)
}

function Start-DetachedRetract {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $sessionCreds = Join-Path (Get-WaSessionDir) 'creds.json'
  if (-not (Test-Path -LiteralPath $waJs) -or -not (Test-Path -LiteralPath $sessionCreds)) {
    return
  }
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
        Write-UiLine "  $DIM   Dev server durduruldu - PID $spid.$RST"
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

function Get-CloudflaredProcesses {
  $list = New-Object System.Collections.Generic.List[object]
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
    $name = [string]$_.Name
    $exe = [string]$_.ExecutablePath
    if ($name -eq 'cloudflared.exe' -or $exe -match '(?i)\\cloudflared(\.exe)?$') {
      [void]$list.Add($_)
    }
  }
  return $list
}

function Test-CloudflaredBelongsToProduct([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  $portNeedle = "127.0.0.1:$Port"
  if ($CommandLine.IndexOf($portNeedle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  if ($StateDir -and $CommandLine.IndexOf($StateDir, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  if ($LogFile -and $CommandLine.IndexOf($LogFile, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  if ($OutLogFile -and $CommandLine.IndexOf($OutLogFile, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  return $false
}

function Get-ProductCloudflaredProcesses {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($proc in @(Get-CloudflaredProcesses)) {
    $cmd = [string]$proc.CommandLine
    $parentLine = ''
    if ($proc.ParentProcessId) {
      $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
      if ($parent) { $parentLine = [string]$parent.CommandLine }
    }
    $blob = $cmd + ' ' + $parentLine
    if (Test-CloudflaredBelongsToProduct $blob) { [void]$list.Add($proc) }
  }
  return $list
}

function Test-CloudflaredAlive {
  $found = @(Get-ProductCloudflaredProcesses)
  if ($found.Count -gt 0) { return $true }
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    $name = (Get-Process -Id $tpid -ErrorAction SilentlyContinue).ProcessName
    if ($name -eq 'cloudflared') { return $true }
  }
  return $false
}

function Sync-CloudflaredPid {
  $proc = @(Get-ProductCloudflaredProcesses) | Select-Object -First 1
  if ($proc -and $proc.ProcessId) {
    Set-Content -LiteralPath $PidFile -Value $proc.ProcessId -Encoding Ascii
  }
}

function Read-TryCloudflareUrl([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $found = [regex]::Matches($Text, 'https://[a-zA-Z0-9\-]+\.(?:trycloudflare\.com|cfargotunnel\.com)')
  if ($found.Count -eq 0) { return $null }
  return $found[$found.Count - 1].Value.Trim().TrimEnd('/')
}

function Recover-TunnelUrl {
  foreach ($proc in @(Get-ProductCloudflaredProcesses)) {
    $parentLine = ''
    if ($proc.ParentProcessId) {
      $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
      if ($parent) { $parentLine = [string]$parent.CommandLine }
    }
    $blob = ([string]$proc.CommandLine) + ' ' + $parentLine
    foreach ($match in [regex]::Matches($blob, '"([^"]+\.log)"')) {
      $path = $match.Groups[1].Value
      if (-not (Test-Path -LiteralPath $path)) { continue }
      $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
      $url = Read-TryCloudflareUrl $text
      if ($url) {
        $dir = Split-Path -Parent $UrlFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($UrlFile, $url)
        return $url
      }
    }
  }
  return (Get-TunnelUrl)
}

function Test-PublicUrlLive([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https://') { return $false }
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    try {
      $pub = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 $Url
      $n = 0
      if ([int]::TryParse("$pub", [ref]$n) -and $n -ge 200 -and $n -le 399) { return $true }
    } catch {}
  }
  try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 8
    return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { return $false }
    return ($code -ge 200 -and $code -lt 400)
  }
}

function Invoke-NslookupText([string[]]$LookupArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'nslookup.exe'
  $quoted = foreach ($part in $LookupArgs) {
    if ($part -match '\s') { '"' + $part + '"' } else { $part }
  }
  $psi.Arguments = ($quoted -join ' ')
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  try { [void]$proc.Start() } catch { return '' }
  if (-not $proc.WaitForExit(4000)) {
    try { $proc.Kill() } catch {}
    return ''
  }
  return ($proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd())
}

function Test-PublicDns([string]$HostName) {
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
  foreach ($server in @('1.1.1.1', '8.8.8.8', '')) {
    $lookupArgs = @('-type=A', $HostName)
    if ($server) { $lookupArgs += $server }
    $out = Invoke-NslookupText $lookupArgs
    if ($out -match '(?i)NXDOMAIN|Non-existent|can.t find|bulunamad') { continue }
    $ips = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($out, '(?m)^[ \t]*(?:Address|Addresses|Adres|Adresler)[ \t]*:[ \t]*([0-9a-fA-F:.]+)')) {
      $ip = $m.Groups[1].Value.Trim()
      if ($ip) { [void]$ips.Add($ip) }
    }
    if ($server) {
      $ips = @($ips | Where-Object { $_ -ne $server -and $_ -ne '127.0.0.1' })
    } elseif ($ips.Count -gt 1) {
      $ips = @($ips | Select-Object -Skip 1)
    } else {
      $ips = @()
    }
    if ($ips.Count -gt 0) { return $true }
  }
  try {
    $found = @(Resolve-DnsName -Name $HostName -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
    if ($found.Count -gt 0) { return $true }
  } catch {}
  return $false
}

function Test-TunnelRegistered {
  if (-not (Test-Path -LiteralPath $LogFile)) { return $false }
  return [bool](Select-String -LiteralPath $LogFile -Pattern 'Registered tunnel connection' -SimpleMatch -Quiet)
}

function Test-NslookupHasA([string]$HostName, [string]$Server) {
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
  $lookupArgs = @('-type=A', $HostName)
  if ($Server) { $lookupArgs += $Server }
  $out = Invoke-NslookupText $lookupArgs
  if (-not $out) { return $false }
  if ($out -match '(?i)NXDOMAIN|Non-existent|can.t find|bulunamad') { return $false }
  $ips = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches($out, '(?m)^[ \t]*(?:Address|Addresses|Adres|Adresler)[ \t]*:[ \t]*([0-9a-fA-F:.]+)')) {
    $ip = $m.Groups[1].Value.Trim()
    if ($ip) { [void]$ips.Add($ip) }
  }
  if ($Server) {
    $ips = @($ips | Where-Object { $_ -ne $Server -and $_ -ne '127.0.0.1' })
  } elseif ($ips.Count -gt 1) {
    $ips = @($ips | Select-Object -Skip 1)
  } else {
    $ips = @()
  }
  return ($ips.Count -gt 0)
}

function Wait-TunnelNameVisible([string]$Url, [int]$Seconds = 90) {
  if ($Url -notmatch '^https://([^/:]+)') { return $false }
  $hostName = $Matches[1]
  $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
  $noted = $false
  while ([datetime]::UtcNow -lt $deadline) {
    if (-not (Test-CloudflaredAlive)) { return $false }
    $public = (Test-NslookupHasA $hostName '1.1.1.1') -and (Test-NslookupHasA $hostName '8.8.8.8')
    if ($public -and (Test-NslookupHasA $hostName '')) {
      try { Clear-DnsClientCache | Out-Null } catch {}
      return $true
    }
    if (-not $noted) {
      Write-UiLine "  $DIM   Yayın adresi DNS'e düşüyor...$RST"
      $noted = $true
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Wait-PublicTunnelReady([string]$Url, [int]$Seconds = 60) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
  while ([datetime]::UtcNow -lt $deadline) {
    if (-not (Get-Process -Name cloudflared -ErrorAction SilentlyContinue)) { return $false }
    if (Test-PublicUrlLive $Url) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Repair-TunnelDns {
  # Only touch adapter DNS when edge resolution actually fails.
  # Forcing 1.1.1.1 on every start fought DHCP/router settings and felt like
  # "DNS keeps breaking" — especially on flaky Wi-Fi / hotspot switches.
  Write-UiLine "  $DIM   DNS kontrol ediliyor...$RST"
  try { Clear-DnsClientCache | Out-Null } catch {}

  $edgeOk = (Test-NslookupHasA 'region1.v2.argotunnel.com' '') -or
    (Test-NslookupHasA 'region1.v2.argotunnel.com' '8.8.8.8') -or
    (Test-NslookupHasA 'region1.v2.argotunnel.com' '1.1.1.1')
  if ($edgeOk) {
    Write-UiLine "  $DIM   Edge DNS OK (region1.v2.argotunnel.com)$RST"
    return $true
  }

  Write-UiLine "  $YEL   Edge DNS zayıf; genel çözümleyiciler deneniyor...$RST"
  # Prefer Google/Quad9 first — some networks partially block Cloudflare anycast.
  $wanted = @('8.8.8.8', '9.9.9.9', '1.1.1.1')
  $changed = $false
  $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
      $_.Status -eq 'Up' -and $_.HardwareInterface -and $_.InterfaceDescription -notmatch '(?i)virtual|hyper-v|vmware|loopback|bluetooth|tailscale|wintun|wireguard'
    })
  if ($adapters.Count -eq 0) {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch '(?i)tailscale|wintun|wireguard|loopback'
      })
  }
  foreach ($adapter in $adapters) {
    $ok = $false
    try {
      Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $wanted -ErrorAction Stop
      $ok = $true
    } catch {
      try {
        & netsh.exe interface ipv4 set dnsservers name="$($adapter.Name)" static 8.8.8.8 primary | Out-Null
        & netsh.exe interface ipv4 add dnsservers name="$($adapter.Name)" 9.9.9.9 index=2 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
      } catch { $ok = $false }
    }
    if ($ok) {
      $changed = $true
      Write-UiLine "  $GRN   DNS düzeltildi: $($adapter.Name) -> 8.8.8.8, 9.9.9.9$RST"
    } else {
      Write-UiLine "  $YEL   DNS yazılamadı ($($adapter.Name)). Yönetici olarak çalıştırmayı deneyin.$RST"
    }
  }
  if ($changed) {
    try { Clear-DnsClientCache | Out-Null } catch {}
    Start-Sleep -Milliseconds 500
  }
  $edgeOk = (Test-NslookupHasA 'region1.v2.argotunnel.com' '8.8.8.8') -or (Test-NslookupHasA 'region1.v2.argotunnel.com' '1.1.1.1')
  if ($edgeOk) {
    Write-UiLine "  $DIM   Edge DNS OK (region1.v2.argotunnel.com)$RST"
  } else {
    Write-UiLine "  $YEL   Edge DNS hâlâ zayıf; tünel yine de denenecek.$RST"
  }
  return $edgeOk
}

function Get-CloudflaredTunnelArgs([string]$Target) {
  # --no-prechecks: avoid hard-fail exits on flaky UDP/QUIC probes when http2 works.
  # http2 + IPv4: skip QUIC/IPv6 paths that time out on many Turkish ISP/mobile hotspots.
  return @(
    'tunnel',
    '--url', $Target,
    '--http-host-header', "127.0.0.1:$Port",
    '--no-autoupdate',
    '--no-prechecks',
    '--protocol', 'http2',
    '--edge-ip-version', '4',
    '--retries', '8'
  )
}

function Test-TunnelDnsResolverFailed {
  if (-not (Test-Path -LiteralPath $LogFile)) { return $false }
  return [bool](Select-String -LiteralPath $LogFile -Pattern 'Failed to initialize DNS local resolver|lookup region\d+\.v2\.argotunnel\.com: i/o timeout' -Quiet)
}

function Stop-ProductCloudflared {
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) { Stop-ProcessTree $tpid }
  foreach ($proc in @(Get-ProductCloudflaredProcesses)) {
    if ($proc.ProcessId) { Stop-ProcessTree $proc.ProcessId }
  }
}

function Start-QuickTunnelOnce([string]$Cloudflared) {
  # Only stop this product's tunnel — never kill the other product's cloudflared.
  Stop-ProductCloudflared
  Remove-Item -LiteralPath $UrlFile, $LogFile, $OutLogFile -Force -ErrorAction SilentlyContinue
  $target = "http://127.0.0.1:$Port"
  $argList = Get-CloudflaredTunnelArgs -Target $target
  $argStr = ($argList | ForEach-Object {
      if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
  $cfCmd = "`"$Cloudflared`" $argStr > `"$OutLogFile`" 2> `"$LogFile`""
  $env:TUNNEL_NO_PRECHECKS = 'true'
  $proc = Start-HiddenCmd $cfCmd
  if (-not $proc) { return $null }
  Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding Ascii
  Sync-CloudflaredPid
  Start-Sleep -Milliseconds 300
  $waitStart = [datetime]::UtcNow
  $deadline = $waitStart.AddSeconds(90)
  $tick = 0
  while ([datetime]::UtcNow -lt $deadline) {
    $tick++
    $found = Get-TunnelUrl
    if ($found) {
      # Prefer a live connector; URL alone can appear before the edge handshake finishes.
      if ((Test-CloudflaredAlive) -or (Test-TunnelRegistered)) { return $found }
    }
    if (-not (Test-PidAlive $proc.Id) -and -not (Test-CloudflaredAlive)) {
      if (Test-TunnelDnsResolverFailed) {
        Write-UiLine "  $YEL   DNS local resolver zaman aşımı; yeniden denenecek.$RST"
      }
      return $null
    }
    if (($tick % 20) -eq 0) {
      $sec = [int]([datetime]::UtcNow - $waitStart).TotalSeconds
      Write-UiLine "  $DIM   ... $sec saniye beklendi$RST"
    }
    Start-Sleep -Milliseconds 250
  }
  return (Get-TunnelUrl)
}

function Start-QuickTunnelWithRetry([string]$Cloudflared, [int]$Attempts = 3) {
  [void](Repair-TunnelDns)
  for ($i = 1; $i -le $Attempts; $i++) {
    if ($i -gt 1) {
      Write-UiLine "  $DIM   Tünel yeniden deneniyor ($i/$Attempts)...$RST"
      [void](Repair-TunnelDns)
      Start-Sleep -Seconds 2
    }
    $url = Start-QuickTunnelOnce -Cloudflared $Cloudflared
    if ($url -and (Test-CloudflaredAlive)) { return $url }
    if ($url -and (Test-TunnelRegistered)) { return $url }
    Stop-TunnelOnly
  }
  return $null
}

function Test-LinkAlreadySent([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  $file = Join-Path (Get-WaSessionDir) 'sent-links.json'
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  $raw = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
  return ($raw -and $raw.Contains($Url))
}

function Test-TunnelRunning {
  if (Test-CloudflaredAlive) { return $true }
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    $name = (Get-Process -Id $tpid -ErrorAction SilentlyContinue).ProcessName
    if ($name -eq 'cloudflared') { return $true }
  }
  return $false
}

function Stop-TunnelOnly {
  Stop-TunnelWatchdog
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Stop-ProcessTree $tpid
    Write-UiLine "  $DIM   Tünel durduruldu - PID $tpid.$RST"
  }
  foreach ($proc in @(Get-ProductCloudflaredProcesses)) {
    if ($proc.ProcessId) { Stop-ProcessTree $proc.ProcessId }
  }
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
}

function Stop-TunnelAndDevServer {
  # Used by [4] cancel — stop this product's tunnel + the tool-started dev server
  if (Test-TunnelRunning) {
    Stop-TunnelOnly
  } else {
    Write-UiLine "  $DIM   Aktif tünel servisi yok.$RST"
    Stop-ProductCloudflared
    Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  }
  Stop-DevServer
  Remove-DuendeeDesktopAppInstall
}

function Stop-AllToolProcesses {
  Stop-TunnelWatchdog
  $tpid = Read-TunnelPid
  if ($tpid -and (Test-PidAlive $tpid)) {
    Stop-ProcessTree $tpid
    Write-UiLine "  $RED   Tünel servisi durduruldu - PID $tpid.$RST"
  } elseif ($tpid) {
    Write-UiLine "  $DIM   PID $tpid zaten çalışmıyor.$RST"
  } else {
    Write-UiLine "  $DIM   Tanımlı çalışan tünel servisi yok.$RST"
  }
  Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object { Stop-ProcessTree $_.Id }
  Stop-DevServer
  Remove-DuendeeDesktopAppInstall
  Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue
  Get-Process PhotosApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'duendee-whatsapp-qr.png') -Force -ErrorAction SilentlyContinue
}

function Get-BannerColor {
  if ($script:ActiveProduct -eq 'duendee') { return $PURPLE }
  return $SALMON
}

function Show-Logo {
  # FIGlet "ANSI Shadow" — same layered block style as Claude Code
  $hue = Get-BannerColor
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
    Write-UiLine ("$hue$BOLD  $r$RST")
  }
  Write-UiLine ''
  Write-UiLine "$DIM   ───────────────────────────────────────────────────────────$RST"
  Write-UiLine "$hue$BOLD          D U E N D E E   T U N N E L   T O O L$RST"
  Write-UiLine "$DIM   ───────────────────────────────────────────────────────────$RST"
  Write-UiLine ''
}

function Show-RootMenu {
  Initialize-Utf8Console
  Clear-Host
  $script:ActiveProduct = 'fm'
  Show-Logo
  Write-UiLine "  $BOLD  Ürün seçin$RST"
  Write-UiLine ''
  Write-UiLine "  [1]  DuendeeFM"
  Write-UiLine "       $DIM   Yayın / tünel / app (Duendee-fm · port $($script:FmPort))$RST"
  Write-UiLine ''
  Write-UiLine "  [2]  Duendee"
  Write-UiLine "       $DIM   Test tüneli (Duendee-main · port $($script:DuendeePort) · ayrı servis)$RST"
  Write-UiLine ''
  Write-UiLine "  $DIM$BOLD[X]$RST  ${DIM}Çıkış$RST"
  Write-UiLine ''
  Write-Ui "$DIM   Seçim: $RST"
}

function Show-Menu {
  # DuendeeFM submenu — existing options preserved
  Initialize-Utf8Console
  Clear-Host
  $autoMode = Get-AutoMode
  Show-Logo
  Write-UiLine "  $SALMON$BOLD  DuendeeFM$RST"
  Write-UiLine "  $DIM   $($script:FmProject)$RST"
  Write-UiLine "  $DIM   port $($script:FmPort)  ·  state .tunnelstate$RST"
  Write-UiLine ''
  Write-UiLine "  [1]  Tünel Servisi Başlat"
  Write-UiLine "  [2]  Servis Durumunu Kontrol Et"
  Write-UiLine "  [3]  Yayın Linkini Kopyala"
  Write-UiLine "  [4]  Tünel Servisini İptal Et"
  $autoLabel = switch ($autoMode) {
    'tool' { "$GRN[TOOL]$RST" }
    'tunnel' { "$GRN[TOOL+TÜNEL]$RST" }
    default { "$RED[KAPALI]$RST" }
  }
  $launchLabel = switch (Get-LaunchType) {
    'desktop' { "$GRN[MASAÜSTÜ]$RST" }
    'mobile' { "$GRN[MOBİL]$RST" }
    'all' { "$GRN[HEPSİ]$RST" }
    default { "$GRN[TARAYICI]$RST" }
  }
  Write-UiLine "  [5]  Cihaz Açılışında Otomatik Başlat  $autoLabel  $launchLabel"
  Write-UiLine "  [6]  Aracı Cihazdan Kaldır"
  Write-UiLine "  $DIM$BOLD[B]$RST  ${DIM}Ürün menüsüne dön$RST"
  Write-UiLine ''
  Write-Ui "$DIM   Seçim: $RST"
}

function Show-DuendeeMenu {
  Initialize-Utf8Console
  Clear-Host
  [void](Ensure-NeoDuendeeAutoDetect)
  Show-Logo
  Write-UiLine "  $PURPLE$BOLD  Duendee$RST  $DIM(Duendee-main)$RST"
  $pathLabel = if ($script:DuendeeProject) { $script:DuendeeProject } else { '(otomatik bulunamadı)' }
  Write-UiLine "  $DIM   $pathLabel$RST"
  Write-UiLine "  $DIM   port $($script:DuendeePort)  ·  branch $($script:DuendeeBranch)  ·  state .tunnelstate-duendee$RST"
  $devOn = Test-PortListening $script:DuendeePort
  $tunOn = Test-TunnelRunning
  Write-UiLine ("  $DIM   Dev Server: {0}  ·  Tünel: {1}$RST" -f $(if ($devOn) { 'AÇIK' } else { 'kapalı' }), $(if ($tunOn) { 'AÇIK' } else { 'kapalı' }))
  Write-UiLine ''
  Write-UiLine "  [1]  Test Tüneli Başlat"
  Write-UiLine "  [2]  Dev Server Başlat  $DIM(localhost:$($script:DuendeePort) · anlık HMR)$RST"
  Write-UiLine "  [3]  Servis Durumunu Kontrol Et"
  Write-UiLine "  [4]  Yayın Linkini Kopyala"
  Write-UiLine "  [5]  Test Tünelini İptal Et"
  Write-UiLine "  [6]  Dev Server'ı Durdur"
  Write-UiLine "  $DIM$BOLD[B]$RST  ${DIM}Ürün menüsüne dön$RST"
  Write-UiLine ''
  Write-Ui "$DIM   Seçim: $RST"
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
  Write-UiLine "$C2   --- Servis Durumu ---$RST"
  Write-UiLine ''
  if (Test-PortListening $Port) {
    Write-UiLine "  Dev Server ........ ${GRN}ÇALIŞIYOR$RST  -  http://localhost:$Port"
  } else {
    Write-UiLine "  Dev Server ........ ${RED}KAPALI$RST"
  }
  $running = Test-TunnelRunning
  if ($running) { Sync-CloudflaredPid }
  if ($running -and -not (Test-TunnelWatchdogAlive)) { Start-TunnelWatchdog }
  $localUrl = if ($running) { Recover-TunnelUrl } else { '' }
  if (-not $localUrl -and $running) { $localUrl = Get-TunnelUrl }
  $publicOk = $false
  if ($localUrl) { $publicOk = Test-PublicUrlLive $localUrl }
  if ($publicOk -and $script:ActiveProduct -ne 'duendee') {
    $env:DT_FLEET_QUIET = '1'
    [void](Invoke-Fleet publish --url "$localUrl")
    Remove-Item Env:DT_FLEET_QUIET -ErrorAction SilentlyContinue
    Start-FleetHeartbeat
  }
  $fleetUrl = ''
  if (-not $publicOk -and $script:ActiveProduct -ne 'duendee') {
    $fleetUrl = "$(Invoke-Fleet show)".Trim()
    if ($script:FleetExit -ne 0) { $fleetUrl = '' }
  }
  $url = if ($publicOk) { $localUrl } else { $fleetUrl }
  $productName = Get-ProductDisplayName
  Write-UiLine "  Ürün ............... $productName"
  if ($running -and $localUrl) {
    Write-UiLine "  Tünel Servisi ..... ${GRN}ÇALIŞIYOR$RST"
    Write-UiLine "  Yayın Linki ......... $(Format-ProductTunnelLine $localUrl)"
    if (-not $publicOk) {
      Write-UiLine "  $RED   Adres henüz dışarıdan yanıt vermiyor.$RST"
    }
  } elseif ($publicOk -or $fleetUrl) {
    Write-UiLine "  Tünel Servisi ..... ${GRN}ÇALIŞIYOR$RST"
    Write-UiLine "  Yayın Linki ......... $(Format-ProductTunnelLine $url)"
  } elseif ($running) {
    Write-UiLine "  Tünel Servisi ..... ${GRN}ÇALIŞIYOR$RST"
    Write-UiLine "  $RED   Yayın linki okunamadı.$RST"
  } else {
    Write-UiLine "  Tünel Servisi ..... ${RED}KAPALI$RST"
  }
  if ($running) {
    if (Test-TunnelWatchdogAlive) {
      Write-UiLine "  Tünel Gözcüsü ..... ${GRN}ÇALIŞIYOR$RST"
    } else {
      Write-UiLine "  Tünel Gözcüsü ..... ${RED}KAPALI$RST"
    }
  }
  if (Test-Path -LiteralPath $LogFile) { Show-LogTail -Brief }
  Complete-Action
}

function Invoke-CopyLink {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  $url = if (Test-TunnelRunning) { Get-TunnelUrl } else { $null }
  $localDead = $false
  if ($url -and -not (Test-PublicUrlLive $url)) { $url = $null; $localDead = $true }
  if ($localDead) {
    Write-UiLine "  $YEL   Tünel adresi dışarıdan yanıt vermiyor. Gözcü yeni adres açıyor...$RST"
    Start-TunnelWatchdog
  }
  if (-not $url -and $script:ActiveProduct -ne 'duendee') {
    $remote = Invoke-Fleet show
    if ($script:FleetExit -eq 0) { $url = "$remote".Trim() }
  }
  if (-not $url) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Aktif yayın linki yok."
    Write-UiLine "  $DIM   Önce [1] ile tünel servisini başlatın.$RST"
    Complete-Action
    return
  }
  Set-Clipboard -Value $url
  Write-UiLine "  $GRN   Yayın linki panoya kopyalandı:$RST"
  Write-UiLine ("  " + (Format-ProductTunnelLine $url))
  Complete-Action
}

function Test-EnvHasSupabase([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $false }
  return ($raw -match '(?m)^\s*VITE_SUPABASE_URL=https://' -and $raw -match '(?m)^\s*VITE_SUPABASE_ANON_KEY=eyJ')
}

function Stop-ListenersOnPort([int]$PortNum) {
  $lines = & netstat.exe -ano -p tcp | Select-String -Pattern (":$PortNum\s+.*LISTENING\s+(\d+)")
  foreach ($line in $lines) {
    if ($line.Line -match '\s(\d+)\s*$') {
      $procId = [int]$Matches[1]
      if ($procId -gt 0 -and $procId -ne $PID) { Stop-ProcessTree $procId }
    }
  }
}

function Test-BundleMissingSupabase {
  $assets = Join-Path $Project 'dist\assets'
  if (-not (Test-Path -LiteralPath $assets)) { return $true }
  $hit = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue |
    Select-String -Pattern 'Missing Supabase environment variables' -SimpleMatch -List -Quiet
  return [bool]$hit
}

function Test-AppBuildStale {
  $index = Join-Path $Project 'dist\index.html'
  if (-not (Test-Path -LiteralPath $index)) { return $true }
  if (Test-BundleMissingSupabase) { return $true }
  $stamp = (Get-Item -LiteralPath $index).LastWriteTime
  foreach ($rel in @('src', 'index.html', '.env', '.env.local', 'vite.config.ts', 'vite.config.js', 'vite.config.mjs')) {
    $p = Join-Path $Project $rel
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $item = Get-Item -LiteralPath $p
    if (-not $item.PSIsContainer) {
      if ($item.LastWriteTime -gt $stamp) { return $true }
      continue
    }
    $newer = Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $stamp } |
      Select-Object -First 1
    if ($newer) { return $true }
  }
  return $false
}

function Test-OriginBundleBroken {
  $html = ''
  try { $html = & curl.exe -fsS --max-time 5 "http://127.0.0.1:$Port/" } catch { return $false }
  if ($html -notmatch 'src="(/assets/index-[^"]+\.js)"') { return $false }
  $jsPath = $Matches[1]
  $tmp = Join-Path $env:TEMP 'duendee-origin-check.js'
  & curl.exe -fsS --max-time 8 -o $tmp "http://127.0.0.1:$Port$jsPath" | Out-Null
  if (-not (Test-Path -LiteralPath $tmp)) { return $false }
  $hit = Select-String -LiteralPath $tmp -Pattern 'Missing Supabase environment variables' -SimpleMatch -Quiet
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  return [bool]$hit
}

function Start-AppOrigin {
  $viteCmd = Join-Path $Project 'node_modules\vite\bin\vite.js'
  $node = Find-NodeExe
  $hasVite = (Test-Path -LiteralPath $viteCmd) -and $node -and (
    (Test-Path -LiteralPath (Join-Path $Project 'vite.config.ts')) -or
    (Test-Path -LiteralPath (Join-Path $Project 'vite.config.js')) -or
    (Test-Path -LiteralPath (Join-Path $Project 'vite.config.mjs'))
  )
  # Duendee (main) test tunnel: vite dev only — skip slow/fragile production build.
  $useDevOnly = ($script:ActiveProduct -eq 'duendee')
  $usePreview = $hasVite -and -not $useDevOnly
  $serverOut = Join-Path $StateDir 'server.out.log'
  $serverErr = Join-Path $StateDir 'server.err.log'
  $buildLog = Join-Path $StateDir 'server.build.log'
  $maxAttempts = if ($useDevOnly) { 1 } else { 2 }
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Ensure-SupabaseEnv
    if ($usePreview -and (Test-AppBuildStale)) {
      Push-Location $Project
      try {
        & npm run build *> $buildLog
        if ($LASTEXITCODE -ne 0) {
          Write-UiLine "  $RED$BOLD   [HATA]$RST npm run build başarısız."
          return $false
        }
      } finally { Pop-Location }
    } elseif ($usePreview) {
      Write-UiLine "  $DIM   Mevcut derleme kullanılacak.$RST"
    }
    if ($useDevOnly -and $hasVite) {
      Write-UiLine "  $DIM   Vite dev (port $Port) — build atlandı.$RST"
      $cmd = "cd /d `"$Project`" & `"$node`" `"$viteCmd`" --host 127.0.0.1 --port $Port --strictPort > `"$serverOut`" 2> `"$serverErr`""
    } elseif ($usePreview) {
      $cmd = "cd /d `"$Project`" & `"$node`" `"$viteCmd`" preview --host 127.0.0.1 --port $Port --strictPort > `"$serverOut`" 2> `"$serverErr`""
    } else {
      $cmd = "cd /d `"$Project`" & npm run dev -- --host 127.0.0.1 --port $Port --strictPort > `"$serverOut`" 2> `"$serverErr`""
    }
    $p = Start-HiddenCmd $cmd
    if ($p) { Set-Content -LiteralPath $ServerPidFile -Value $p.Id -Encoding Ascii }
    $ready = $false
    $waitTicks = if ($useDevOnly) { 120 } else { 80 }
    for ($i = 1; $i -le $waitTicks; $i++) {
      if (Test-PortListening $Port) { $ready = $true; break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { return $false }
    if ($useDevOnly) { return $true }
    if (-not (Test-OriginBundleBroken)) { return $true }
    Write-UiLine "  $DIM   Sunulan paket Supabase ayarı içermiyor, yeniden derleniyor.$RST"
    Stop-DevServer
    Stop-ListenersOnPort $Port
    Remove-Item -LiteralPath (Join-Path $Project 'dist\index.html') -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
  Write-UiLine "  $RED$BOLD   [HATA]$RST Yayın hâlâ Supabase ayarı olmadan açılıyor."
  return $false
}

function Ensure-SupabaseEnv {
  # Clones omit .env. Vite then ships a bundle that throws before the page renders.
  if ((Test-EnvHasSupabase (Join-Path $Project '.env')) -or (Test-EnvHasSupabase (Join-Path $Project '.env.local'))) {
    return
  }
  $url = if ($env:DT_VITE_SUPABASE_URL) { $env:DT_VITE_SUPABASE_URL } else { 'https://ytlliifgpbiagidduhsx.supabase.co' }
  $key = if ($env:DT_VITE_SUPABASE_ANON_KEY) { $env:DT_VITE_SUPABASE_ANON_KEY } else { 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl0bGxpaWZncGJpYWdpZGR1aHN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1NjAyOTAsImV4cCI6MjA4OTEzNjI5MH0.W4p97en1IP7NTF304lCuVsyyvRINqa01yDnwCgOzBj4' }
  $target = Join-Path $Project '.env.local'
  @(
    "VITE_SUPABASE_URL=$url"
    "VITE_SUPABASE_ANON_KEY=$key"
    'VITE_APP_VARIANT=main'
  ) | Set-Content -LiteralPath $target -Encoding ascii
  Write-UiLine "  $DIM   Supabase istemci ayarı yazıldı (.env yoktu).$RST"
}

function Invoke-Fleet {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FleetArgs)
  $script:FleetExit = 1
  $script:FleetError = ''
  $node = Find-NodeExe
  $js = Join-Path $Root 'scripts\fleet.js'
  if (-not $node -or -not (Test-Path -LiteralPath $js)) { return $null }
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  try {
    $lines = @(& $node $js @FleetArgs --root $Root 2>&1)
    $script:FleetExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
  }
  $stdout = New-Object System.Collections.Generic.List[string]
  $stderr = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($lines)) {
    if ($line -is [System.Management.Automation.ErrorRecord]) { [void]$stderr.Add("$line") }
    else { [void]$stdout.Add("$line") }
  }
  $script:FleetError = ($stderr -join "`n").Trim()
  return ($stdout -join "`n").Trim()
}

function Invoke-FleetRelease {
  [void](Invoke-Fleet release)
}

function Start-FleetHeartbeat {
  $pidFile = Join-Path $StateDir 'fleet-heartbeat.pid'
  if (Test-Path -LiteralPath $pidFile) {
    $raw = Get-Content -LiteralPath $pidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $hpid = 0
    if ([int]::TryParse("$raw".Trim(), [ref]$hpid) -and (Test-PidAlive $hpid)) { return }
  }
  $node = Find-NodeExe
  $js = Join-Path $Root 'scripts\fleet.js'
  if (-not $node) { return }
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  Set-Content -LiteralPath (Join-Path $StateDir 'fleet-heartbeat.on') -Value '1' -Encoding Ascii
  [void](Start-HiddenDetached -CommandLine "`"$node`" `"$js`" heartbeat --root `"$Root`"")
}

function Get-WatchdogPidFile {
  Join-Path $StateDir 'watchdog.pid'
}

function Test-TunnelWatchdogAlive {
  $file = Get-WatchdogPidFile
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  $raw = Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction SilentlyContinue
  $wpid = 0
  if ([int]::TryParse("$raw".Trim(), [ref]$wpid) -and $wpid -gt 0) { return (Test-PidAlive $wpid) }
  return $false
}

function Stop-TunnelWatchdog {
  $file = Get-WatchdogPidFile
  if (-not (Test-Path -LiteralPath $file)) { return }
  $raw = Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction SilentlyContinue
  $wpid = 0
  if ([int]::TryParse("$raw".Trim(), [ref]$wpid) -and $wpid -gt 0 -and (Test-PidAlive $wpid)) {
    Stop-ProcessTree $wpid
  }
  Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

function Start-TunnelWatchdog {
  # Keeps the quick tunnel alive: if the hostname leaves DNS (NXDOMAIN) or
  # cloudflared dies, a fresh tunnel is opened and the new link is shared.
  $node = Find-NodeExe
  $js = Join-Path $Root 'scripts\tunnel-watchdog.js'
  if (-not $node -or -not (Test-Path -LiteralPath $js)) { return }
  if (Test-TunnelWatchdogAlive) { return }
  $cf = Find-Cloudflared
  if (-not $cf) { return }
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  $cmd = "`"$node`" `"$js`" --root `"$Root`" --port $Port --cloudflared `"$cf`" --project `"$Project`""
  if (Start-HiddenDetached -CommandLine $cmd) { return }
  Start-Process -FilePath $node -WindowStyle Hidden -ArgumentList @(
    $js, '--root', $Root, '--port', "$Port", '--cloudflared', $cf, '--project', $Project
  ) | Out-Null
}

function Update-ToolCopy {
  if ($env:DT_SKIP_UPDATE -eq '1') { return }
  $node = Find-NodeExe
  $js = Join-Path $Root 'scripts\fleet.js'
  if (-not $node -or -not (Test-Path -LiteralPath $js)) { return }
  & $node $js update --root $Root
  if ($LASTEXITCODE -eq 20) {
    $script:CleanupDone = $true
    $reargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Action) { $reargs += $Action }
    if ($UninstallChoice) { $reargs += $UninstallChoice }
    & powershell.exe @reargs
    exit $LASTEXITCODE
  }
}

function Get-DuendeeDepStamp([string]$Path) {
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($name in @('package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock')) {
    $file = Join-Path $Path $name
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      [void]$parts.Add((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash)
    } else {
      [void]$parts.Add('-')
    }
  }
  return ($parts -join '|')
}

function Sync-DuendeeForPublish {
  if ($script:ActiveProduct -eq 'duendee') {
    return [bool](Sync-NeoDuendeeForTest)
  }
  if (Test-IsDuendeeMainPath $Project) {
    Write-UiLine "  $RED$BOLD[HATA]$RST projectPath Duendee-main olamaz. Yayına yalnızca Duendee-fm alınır."
    return $false
  }
  if (-not (Test-LooksLikeDuendeeRepo $Project)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST projectPath Duendee-fm deposu değil. Güncel sürüm yayına alınamadı."
    return $false
  }
  Stop-DevServer
  Stop-ListenersOnPort $Port
  Start-Sleep -Milliseconds 300
  if (Test-PortListening $Port) {
    Write-UiLine "  $RED$BOLD[HATA]$RST $Port portu boşaltılamadı. Eski yayın durdurulamadı."
    return $false
  }
  $before = Get-DuendeeDepStamp $Project
  Write-UiLine "  $DIM   Duendee-fm güncel reposu yayına alınıyor...$RST"
  if (-not (Update-DuendeeRepoSafe $Project)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Duendee-fm güncellenemedi. Eski sürüm yayına alınmadı."
    return $false
  }
  $after = Get-DuendeeDepStamp $Project
  if (-not (Test-Path -LiteralPath (Join-Path $Project 'node_modules')) -or $before -ne $after) {
    Write-UiLine "  $DIM   Bağımlılıklar kuruluyor (npm install)...$RST"
    Push-Location $Project
    try {
      & npm install *>&1 | Out-Host
      $npmCode = $LASTEXITCODE
    } finally { Pop-Location }
    if ($npmCode -ne 0) {
      Write-UiLine "  $RED$BOLD   [HATA]$RST npm install başarısız."
      return $false
    }
  }
  $dist = Join-Path $Project 'dist'
  if (Test-Path -LiteralPath $dist) {
    Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath (Join-Path $dist 'index.html')) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Eski derleme silinemedi."
    return $false
  }
  return $true
}

function Resolve-NewestNeoDuendeeBranch([string]$Path, [switch]$FetchRemote) {
  if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return '' }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
  $env:GIT_TERMINAL_PROMPT = '0'
  if ($FetchRemote) {
    try { & git -C $Path fetch origin --prune 2>$null | Out-Null } catch {}
  }
  $bestName = ''
  $bestTs = -1
  try {
    # Trailing slash skips the bare refs/remotes/origin symbolic ref ("origin").
    $lines = @(& git -C $Path for-each-ref --sort=-committerdate `
        --format='%(committerdate:unix)|%(refname)' refs/remotes/origin/ refs/heads/ 2>$null)
    foreach ($line in $lines) {
      $raw = "$line".Trim()
      if (-not $raw) { continue }
      $parts = $raw.Split('|', 2)
      if ($parts.Count -lt 2) { continue }
      $ts = 0
      if (-not [int64]::TryParse($parts[0], [ref]$ts)) { continue }
      $ref = $parts[1]
      $name = ''
      if ($ref -match '^refs/remotes/origin/(.+)$') { $name = $Matches[1] }
      elseif ($ref -match '^refs/heads/(.+)$') { $name = $Matches[1] }
      else { continue }
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      if ($name -eq 'HEAD' -or $name -eq 'origin') { continue }
      if ($ts -gt $bestTs) {
        $bestTs = $ts
        $bestName = $name
      }
    }
  } catch {}
  if ($bestName) { return $bestName }
  try {
    $cur = (& git -C $Path branch --show-current 2>$null)
    if ($cur) { return "$cur".Trim() }
  } catch {}
  return 'main'
}

function Update-NeoDuendeeBranch([string]$Path, [string]$Branch) {
  if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return $false }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
  if ([string]::IsNullOrWhiteSpace($Branch) -or $Branch -eq 'origin' -or $Branch -eq 'HEAD') { return $false }
  $env:GIT_TERMINAL_PROMPT = '0'
  try {
    & git -C $Path fetch origin --prune 2>$null | Out-Null
    $remote = (& git -C $Path rev-parse --verify "origin/$Branch" 2>$null)
    if ($remote) {
      & git -C $Path checkout $Branch 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) {
        & git -C $Path checkout -B $Branch "origin/$Branch" 2>$null | Out-Null
      }
      & git -C $Path pull --ff-only origin $Branch 2>$null | Out-Null
      return $true
    }
    $local = (& git -C $Path rev-parse --verify $Branch 2>$null)
    if ($local) {
      & git -C $Path checkout $Branch 2>$null | Out-Null
      return ($LASTEXITCODE -eq 0)
    }
    return $false
  } catch {
    return $false
  }
}

function Ensure-NeoDuendeeAutoDetect {
  # Fast path for menus: no git fetch (that runs only on tunnel start).
  $script:DuendeePort = 8081
  $found = @(Find-LocalNeoDuendeeRepos)
  if ($found.Count -gt 0) {
    $script:DuendeeProject = $found[0]
  } elseif ($env:DT_NEO_DUENDEE_DIR -and (Test-Path -LiteralPath $env:DT_NEO_DUENDEE_DIR)) {
    $script:DuendeeProject = (Resolve-Path -LiteralPath $env:DT_NEO_DUENDEE_DIR).Path
  }
  if ([string]::IsNullOrWhiteSpace($script:DuendeeProject) -or -not (Test-Path -LiteralPath $script:DuendeeProject)) {
    $script:DuendeeBranch = '(bulunamadı)'
    return $false
  }
  $hint = Resolve-NewestNeoDuendeeBranch $script:DuendeeProject
  if ($hint) { $script:DuendeeBranch = $hint }
  elseif (-not $script:DuendeeBranch -or $script:DuendeeBranch -eq 'origin') { $script:DuendeeBranch = 'main' }
  if ($script:ActiveProduct -eq 'duendee') { Bind-ProductState 'duendee' }
  return $true
}

function Sync-NeoDuendeeForTest {
  if (-not (Ensure-NeoDuendeeAutoDetect)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Duendee-main bulunamadı. Klasörü YEK\Cursor\Duendee-main olarak tutun."
    return $false
  }
  if (-not (Test-LooksLikeNeoDuendeeRepo $Project)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Klasör Duendee-main deposu değil: $Project"
    return $false
  }
  Stop-DevServer
  Stop-ListenersOnPort $Port
  Start-Sleep -Milliseconds 300
  if (Test-PortListening $Port) {
    Write-UiLine "  $RED$BOLD[HATA]$RST $Port portu boşaltılamadı."
    return $false
  }
  $branch = Resolve-NewestNeoDuendeeBranch -Path $Project -FetchRemote
  if (-not $branch -or $branch -eq 'origin') { $branch = 'main' }
  $script:DuendeeBranch = $branch
  Write-UiLine "  $DIM   En güncel Duendee branch hazırlanıyor ($branch)...$RST"
  $before = Get-DuendeeDepStamp $Project
  if (-not (Update-NeoDuendeeBranch -Path $Project -Branch $branch)) {
    Write-UiLine "  $YEL   Branch checkout/pull atlandı veya başarısız; mevcut working tree ile devam.$RST"
  } else {
    Write-UiLine "  $DIM   Branch: $branch$RST"
  }
  Save-ToolConfig -ProjectPath $script:FmProject -PortNum $script:FmPort -AppPath $script:FmAppPath `
    -DuendeeProjectPath $script:DuendeeProject -DuendeePortNum $script:DuendeePort -DuendeeBranch $script:DuendeeBranch
  $after = Get-DuendeeDepStamp $Project
  if (-not (Test-Path -LiteralPath (Join-Path $Project 'node_modules')) -or $before -ne $after) {
    Write-UiLine "  $DIM   Bağımlılıklar kuruluyor (npm install)...$RST"
    Push-Location $Project
    try {
      & npm install *>&1 | Out-Host
      $npmCode = $LASTEXITCODE
    } finally { Pop-Location }
    if ($npmCode -ne 0) {
      Write-UiLine "  $RED$BOLD   [HATA]$RST npm install başarısız."
      return $false
    }
  }
  return $true
}

function Sync-NeoDuendeeCodeOnly {
  # Update branch/deps without killing a running Vite HMR server unless deps changed.
  if (-not (Ensure-NeoDuendeeAutoDetect)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Duendee-main bulunamadı."
    return $false
  }
  if (-not (Test-LooksLikeNeoDuendeeRepo $Project)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Klasör Duendee-main deposu değil: $Project"
    return $false
  }
  $branch = Resolve-NewestNeoDuendeeBranch -Path $Project -FetchRemote
  if (-not $branch -or $branch -eq 'origin') { $branch = 'main' }
  $script:DuendeeBranch = $branch
  Write-UiLine "  $DIM   Branch güncelleniyor ($branch)...$RST"
  $before = Get-DuendeeDepStamp $Project
  if (-not (Update-NeoDuendeeBranch -Path $Project -Branch $branch)) {
    Write-UiLine "  $YEL   Checkout/pull atlandı; mevcut tree ile devam.$RST"
  } else {
    Write-UiLine "  $DIM   Branch: $branch$RST"
  }
  Save-ToolConfig -ProjectPath $script:FmProject -PortNum $script:FmPort -AppPath $script:FmAppPath `
    -DuendeeProjectPath $script:DuendeeProject -DuendeePortNum $script:DuendeePort -DuendeeBranch $script:DuendeeBranch
  $after = Get-DuendeeDepStamp $Project
  $needInstall = -not (Test-Path -LiteralPath (Join-Path $Project 'node_modules')) -or $before -ne $after
  if ($needInstall) {
    if (Test-PortListening $Port) {
      Write-UiLine "  $DIM   Bağımlılık değişti — Dev Server yeniden başlatılacak.$RST"
      Stop-DevServer
      Stop-ListenersOnPort $Port
      Start-Sleep -Milliseconds 300
    }
    Write-UiLine "  $DIM   Bağımlılıklar kuruluyor (npm install)...$RST"
    Push-Location $Project
    try {
      & npm install *>&1 | Out-Host
      $npmCode = $LASTEXITCODE
    } finally { Pop-Location }
    if ($npmCode -ne 0) {
      Write-UiLine "  $RED$BOLD   [HATA]$RST npm install başarısız."
      return $false
    }
  }
  return $true
}

function Invoke-StartDuendeeDevServer {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$C5   --- Duendee Dev Server (localhost:$Port) ---$RST"
  Write-UiLine ''
  if (-not (Sync-NeoDuendeeCodeOnly)) { Complete-Action; return }
  if (Test-PortListening $Port) {
    Write-UiLine "  $GRN   Dev Server zaten çalışıyor.$RST"
    Write-UiLine "  $DIM   http://localhost:$Port  (HMR açık — kaydettikçe yenilenir)$RST"
    try { Start-Process "http://localhost:$Port/" | Out-Null } catch {}
    Complete-Action
    return
  }
  Write-UiLine "  ${C5}[1]$RST Vite dev başlatılıyor (port $Port)..."
  if (-not (Start-AppOrigin)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Dev Server $Port portunda açılamadı."
    Write-UiLine "  $DIM   Ayrıntı: $(Join-Path $StateDir 'server.out.log')$RST"
    Complete-Action
    return
  }
  Write-UiLine "  $GRN   Dev Server hazır: http://localhost:$Port/$RST"
  Write-UiLine "  $DIM   Tünel yok — sadece local. Tünel için [1].$RST"
  try { Start-Process "http://localhost:$Port/" | Out-Null } catch {}
  Complete-Action
}

function Invoke-StopDuendeeDevServer {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$C5   --- Dev Server durduruluyor ---$RST"
  Write-UiLine ''
  if (-not (Test-PortListening $Port)) {
    Write-UiLine "  $DIM   Dev Server zaten kapalı.$RST"
    Complete-Action
    return
  }
  Stop-DevServer
  Stop-ListenersOnPort $Port
  Start-Sleep -Milliseconds 300
  if (Test-PortListening $Port) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Port $Port boşaltılamadı."
  } else {
    Write-UiLine "  $GRN   Dev Server durduruldu.$RST"
  }
  Complete-Action
}

function Invoke-StartDuendeeIsolated {
  # Separate from DuendeeFM fleet — own port, state dir, and cloudflared process.
  $cf = Find-Cloudflared
  if (-not $cf) {
    Write-UiLine "  $RED$BOLD[HATA]$RST cloudflared bulunamadı."
    Complete-Action
    return
  }
  Write-UiLine "  ${C5}[1]$RST cloudflared: $cf  $DIM(Duendee · port $Port)$RST"
  $env:CF = $cf

  if (Test-TunnelRunning) {
    $existing = Recover-TunnelUrl
    if (-not $existing) { $existing = Get-TunnelUrl }
    if ($existing -and (Test-PublicUrlLive $existing)) {
      Write-UiLine "  $GRN   Duendee test tüneli zaten çalışıyor.$RST"
      Write-UiLine "  ${C5}[2]$RST Kod güncelleniyor..."
      if (-not (Sync-NeoDuendeeCodeOnly)) { Complete-Action; return }
      if (-not (Test-PortListening $Port)) {
        if (-not (Start-AppOrigin)) {
          Write-UiLine "  $RED   Uygulama açılamadı. Tünel duruyor ama sayfa erişilemeyebilir.$RST"
        }
      } else {
        Write-UiLine "  $DIM   Mevcut Dev Server kullanılacak (HMR).$RST"
      }
      Set-Clipboard -Value $existing
      Write-UiLine ("  " + (Format-ProductTunnelLine $existing))
      try { Start-Process $existing | Out-Null } catch {}
      Send-TunnelWhatsApp -PublicUrl $existing
      Complete-Action
      return
    }
    Write-UiLine "  $YEL   Eski Duendee tüneli yanıt vermiyor, yenisi açılıyor...$RST"
    Stop-TunnelOnly
  }

  Write-UiLine "  ${C5}[2]$RST En güncel Duendee-main hazırlanıyor..."
  if (-not (Sync-NeoDuendeeCodeOnly)) { Complete-Action; return }
  if (-not (Test-PortListening $Port)) {
    Write-UiLine "  ${C5}[3]$RST Uygulama başlatılıyor (port $Port)..."
    if (-not (Start-AppOrigin)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Uygulama $Port portunda açılamadı."
      Write-UiLine "  $DIM   Ayrıntı: $(Join-Path $StateDir 'server.out.log')$RST"
      Complete-Action
      return
    }
  } else {
    Write-UiLine "  ${C5}[3]$RST Mevcut Dev Server kullanılacak (port $Port)."
  }
  Write-UiLine "  $DIM   Uygulama http://127.0.0.1:$Port hazır.$RST"
  Write-UiLine "  ${C5}[4]$RST Duendee test tüneli açılıyor..."
  $url = Start-QuickTunnelWithRetry -Cloudflared $cf -Attempts 3
  if (-not $url -or (-not (Test-CloudflaredAlive) -and -not (Test-TunnelRegistered))) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel açılmadı."
    Complete-Action
    return
  }
  if ($url) {
    $dir = Split-Path -Parent $UrlFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($UrlFile, $url)
    Set-Clipboard -Value $url
    Write-UiLine ("  " + (Format-ProductTunnelLine $url))
    Write-UiLine "  $GRN   Link panoya kopyalandı.$RST"
    try { Start-Process $url | Out-Null } catch {}
    Send-TunnelWhatsApp -PublicUrl $url
  }
  Start-TunnelWatchdog
  Complete-Action
}

function Invoke-Start {
  if ($env:DT_RECOVER -ne '1') {
    Remove-Item -LiteralPath (Join-Path $StateDir 'manual-stop') -Force -ErrorAction SilentlyContinue
  }
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  if ($script:ActiveProduct -eq 'duendee') {
    Write-UiLine "$C5   --- Duendee test tüneli başlatılıyor ---$RST"
    Write-UiLine ''
    Invoke-StartDuendeeIsolated
    return
  }
  Write-UiLine "$C1   --- Tünel servisi başlatılıyor ---$RST"
  Write-UiLine ''

  $cf = Find-Cloudflared
  if (-not $cf) {
    Write-UiLine "  $RED$BOLD[HATA]$RST cloudflared bulunamadı."
    Complete-Action
    return
  }
  Write-UiLine "  ${C1}[1]$RST cloudflared: $cf"
  $env:CF = $cf

  $script:FleetClaimed = $false
  $script:NeedFreshTunnel = $false
  try {
  $localAlive = Test-TunnelRunning
  $localUrl = if ($localAlive) { Recover-TunnelUrl } else { '' }
  if ($localAlive -and $localUrl -and -not (Test-PublicUrlLive $localUrl)) {
    # The quick tunnel hostname is gone from DNS or the edge dropped it.
    # Reusing it would publish a link that fails with NXDOMAIN everywhere.
    Write-UiLine "  $YEL   Mevcut tünel dışarıdan yanıt vermiyor, yenisi açılıyor...$RST"
    $localAlive = $false
    $localUrl = ''
  }
  if ([string]::IsNullOrWhiteSpace($localUrl)) { $localUrl = '-' }
  $aliveFlag = if ($localAlive) { '1' } else { '0' }
  $decision = Invoke-Fleet begin --local-alive $aliveFlag --local-url "$localUrl"
  if ($script:FleetExit -ne 0 -or [string]::IsNullOrWhiteSpace($decision)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel kaydı okunamadı. Yeni tünel açılmadı."
    if ($script:FleetError) { Write-UiLine "  $DIM   $($script:FleetError)$RST" }
    Complete-Action
    return
  }
  $decision = "$decision".Trim()
  if ($decision.StartsWith('adopt' + "`t") -or $decision.StartsWith('adopt ')) {
    $adoptUrl = ($decision -split "[`t ]", 2)[1].Trim()
    if (Test-TunnelRunning) { Stop-TunnelOnly }
    if ($adoptUrl) {
      $dir = Split-Path -Parent $UrlFile
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      [IO.File]::WriteAllText($UrlFile, $adoptUrl)
    }
    Write-UiLine "  $GRN   Aktif tünel var.$RST"
    Set-Clipboard -Value $adoptUrl
    Write-UiLine "       $adoptUrl"
    if ($script:ActiveProduct -eq 'fm') {
      Start-CompanionApps -TunnelUrl $adoptUrl
    } else {
      try { Start-Process $adoptUrl | Out-Null } catch {}
    }
    Complete-Action
    return
  }
  if ($decision -eq 'keep' -or $decision.StartsWith('keep' + "`t") -or $decision.StartsWith('keep ')) {
    if ($decision -ne 'keep') {
      $keepUrl = ($decision -split "[`t ]", 2)[1].Trim()
      if ($keepUrl) { [IO.File]::WriteAllText($UrlFile, $keepUrl) }
    }
    Start-FleetHeartbeat
    Start-TunnelWatchdog
  $tunnelAlive = $true
  $existing = Recover-TunnelUrl
  if ($tunnelAlive) {
    Write-UiLine "  $GRN   Aktif tünel var.$RST"
    $existing = Recover-TunnelUrl
    if (-not $existing) { $existing = Get-TunnelUrl }
    $syncLabel = if ($script:ActiveProduct -eq 'duendee') { 'Duendee neo-3d test yayını hazırlanıyor...' } else { 'Güncel Duendee-fm yayına alınıyor...' }
    Write-UiLine "  ${C1}[2]$RST $syncLabel"
    if (-not (Sync-DuendeeForPublish)) {
      Complete-Action
      return
    }
    if (-not (Start-AppOrigin)) {
      Write-UiLine "  $RED   Uygulama açılamadı. Tünel duruyor ama sayfa erişilemeyebilir.$RST"
    }
    $cfProc = @(Get-CloudflaredProcesses) | Select-Object -First 1
    if ($cfProc -and $cfProc.ProcessId) {
      Set-Content -LiteralPath $PidFile -Value $cfProc.ProcessId -Encoding Ascii
    }
    if (-not $existing) {
      Write-UiLine "  $RED   Tünel çalışıyor ama yayın linki okunamadı. Kapatmak için [4].$RST"
      Complete-Action
      return
    }
    Set-Clipboard -Value $existing
    Write-UiLine "       $existing"
    if ($script:ActiveProduct -eq 'fm') {
      Start-CompanionApps -TunnelUrl $existing
    } else {
      try { Start-Process $existing | Out-Null } catch {}
    }
    Complete-Action
    return
  }
  }
  if ($decision -ne 'own' -and -not $script:NeedFreshTunnel) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel kaydı okunamadı. Yeni tünel açılmadı."
    Complete-Action
    return
  }
  if (-not $script:NeedFreshTunnel) { $script:FleetClaimed = $true }
  if (Read-TunnelPid) { Remove-Item -LiteralPath $PidFile, $UrlFile -Force -ErrorAction SilentlyContinue }

  if (-not $script:NeedFreshTunnel) {
    $syncLabel2 = if ($script:ActiveProduct -eq 'duendee') { 'Duendee neo-3d test yayını hazırlanıyor...' } else { 'Güncel Duendee-fm yayına alınıyor...' }
    Write-UiLine "  ${C1}[2]$RST $syncLabel2"
    if (-not (Sync-DuendeeForPublish)) {
      Complete-Action
      return
    }
    Write-UiLine "  ${C1}[3]$RST Uygulama başlatılıyor..."
    if (-not (Start-AppOrigin)) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Uygulama $Port portunda açılamadı."
      Write-UiLine "  $DIM   Ayrıntı: $(Join-Path $StateDir 'server.out.log')$RST"
      Complete-Action
      return
    }
  } elseif (-not (Test-PortListening $Port)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Uygulama $Port portunda açılamadı."
    Complete-Action
    return
  }
  Write-UiLine "  $DIM   Uygulama http://127.0.0.1:$Port hazır.$RST"

  Write-UiLine "  ${C1}[4]$RST Tünel açılıyor..."
  $url = Start-QuickTunnelWithRetry -Cloudflared $cf -Attempts 3
  if ($url -and -not (Test-CloudflaredAlive)) {
    Start-Sleep -Milliseconds 800
    Sync-CloudflaredPid
  }
  if (-not $url -or (-not (Test-CloudflaredAlive) -and -not (Test-TunnelRegistered))) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Tünel açılmadı."
    if (Test-TunnelDnsResolverFailed) {
      Write-UiLine "  $YEL   DNS local resolver zaman aşımı görüldü. Wi-Fi DNS'ini 1.1.1.1 / 8.8.8.8 yapıp yönetici olarak tekrar deneyin.$RST"
    }
    Show-LogTail
    Stop-TunnelOnly
    Complete-Action
    return
  }
  if (-not (Test-PortListening $Port)) {
    Write-UiLine "  $RED$BOLD[HATA]$RST Dev server origin $Port portunda yanıt vermiyor."
    Show-LogTail
    Stop-TunnelOnly
    Complete-Action
    return
  }
  $dnsReady = Wait-TunnelNameVisible $url
  Start-TunnelWatchdog
  $liveReady = Wait-PublicTunnelReady $url 45
  Write-UiLine ''
  Write-UiLine "$GRN$BOLD"
  Write-UiLine '  +======================================================+'
  Write-UiLine '  |      YAYIN HAZIR - Diğer cihazlar bağlanabilir!      |'
  Write-UiLine '  +======================================================+'
  Write-UiLine "$RST"
  Write-UiLine ''
  Show-LogTail
  Write-UiLine ''
  if (-not $liveReady) {
    Write-UiLine "  $YEL   Adres şu an dışarıdan yanıt vermiyor. Gözcü tüneli yeniden açacak.$RST"
    Write-UiLine ''
  }
  if ($url) {
    Set-Clipboard -Value $url
    Write-UiLine ("  " + (Format-ProductTunnelLine $url))
    Write-UiLine "  $GRN   Link panoya kopyalandı.$RST  Gerekirse [3] ile yeniden kopyalayın."
    Write-UiLine ''
    if (Test-BrowserOpens -and $dnsReady) {
      Write-UiLine '  Varsayılan tarayıcıda açılıyor...'
      Start-Process $url
    } elseif (Test-BrowserOpens) {
      Write-UiLine "  $DIM   Adres henüz DNS'te yok, tarayıcı açılmadı.$RST"
    } else {
      Write-UiLine "  $DIM   Tarayıcı kapalı. [5] > [B].$RST"
    }
    if ($script:ActiveProduct -eq 'fm') {
      Start-CompanionApps -TunnelUrl $url
      # Mobile APK caption already includes the tunnel URL — skip the extra link message.
      if (-not $script:LastMobileApkSent) {
        Send-TunnelWhatsApp -PublicUrl $url
      } else {
        Write-UiLine "  $DIM   WhatsApp: DuendeeFM APK mesajı gönderildi (ayrı link mesajı yok).$RST"
      }
    }
  }
  if ($script:FleetClaimed -or $script:NeedFreshTunnel) {
    if (-not $url) {
      Write-UiLine "  $RED$BOLD[HATA]$RST Tünel kaydı yazılamadı. Yerel tünel kapatıldı."
      Stop-TunnelOnly
      Complete-Action
      return
    }
    [void](Invoke-Fleet publish --url "$url")
    if ($script:FleetExit -ne 0) {
      if ($script:FleetClaimed) {
        Write-UiLine "  $RED$BOLD[HATA]$RST Tünel kaydı yazılamadı. Yerel tünel kapatıldı."
        Stop-TunnelOnly
      } else {
        Write-UiLine "  $DIM   Yeni adres kayda yazılamadı. Yerel yayın duruyor.$RST"
      }
      Complete-Action
      return
    }
    $script:FleetClaimed = $false
    Start-FleetHeartbeat
  }
  Complete-Action
  } finally {
    if ($script:FleetClaimed) {
      Invoke-FleetRelease
      $script:FleetClaimed = $false
    }
  }
}

function Invoke-Cancel {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$C4   --- Tünel servisini iptal et ---$RST"
  Write-UiLine ''
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  Set-Content -LiteralPath (Join-Path $StateDir 'manual-stop') -Value '1' -Encoding Ascii
  Stop-TunnelOnly
  Stop-DevServer
  Remove-DuendeeDesktopAppInstall
  $fleetRole = "$(Invoke-Fleet role)".Trim()
  if ($fleetRole -eq 'other') {
    Write-UiLine "  ${RED}   Aktif tünel kapatılıyor...$RST"
    [void](Invoke-Fleet stop)
  }
  [void](Invoke-Fleet clear)
  Invoke-RetractWhatsApp
  Write-UiLine "  $RED   Tünel kapatıldı.$RST"
  Complete-Action
}

function Get-LaunchTypePath {
  Join-Path $StateDir 'launch-type'
}

function Get-LaunchType {
  $path = Get-LaunchTypePath
  if (Test-Path -LiteralPath $path) {
    $raw = ("$(Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue)").Trim().ToLowerInvariant()
    if ($raw -in @('browser', 'desktop', 'mobile', 'all')) { return $raw }
  }
  # Migrate older independent flags once.
  $browserFile = Join-Path $StateDir 'open-browser'
  $deskFile = Join-Path $StateDir 'launch-desktop'
  $mobFile = Join-Path $StateDir 'launch-mobile'
  $browserOn = $true
  if (Test-Path -LiteralPath $browserFile) {
    $browserOn = ("$(Get-Content -LiteralPath $browserFile -TotalCount 1 -ErrorAction SilentlyContinue)").Trim() -ne '0'
  }
  $deskOn = $false
  if (Test-Path -LiteralPath $deskFile) {
    $deskOn = ("$(Get-Content -LiteralPath $deskFile -TotalCount 1 -ErrorAction SilentlyContinue)").Trim() -ne '0'
  }
  $mobOn = $false
  if (Test-Path -LiteralPath $mobFile) {
    $mobOn = ("$(Get-Content -LiteralPath $mobFile -TotalCount 1 -ErrorAction SilentlyContinue)").Trim() -ne '0'
  }
  if ($deskOn -and $mobOn -and $browserOn) { return 'all' }
  if ($deskOn -and -not $mobOn -and -not $browserOn) { return 'desktop' }
  if ($mobOn -and -not $deskOn -and -not $browserOn) { return 'mobile' }
  if ($deskOn -or $mobOn) { return 'all' }
  return 'browser'
}

function Set-LaunchType([string]$Type) {
  $normalized = "$Type".Trim().ToLowerInvariant()
  if ($normalized -notin @('browser', 'desktop', 'mobile', 'all')) { $normalized = 'browser' }
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Set-Content -LiteralPath (Get-LaunchTypePath) -Value $normalized -Encoding Ascii
}

function Get-LaunchTypeLabel([string]$Type = '') {
  if ([string]::IsNullOrWhiteSpace($Type)) { $Type = Get-LaunchType }
  switch ($Type) {
    'desktop' { return 'Masaüstü App' }
    'mobile' { return 'Mobil App' }
    'all' { return 'Hepsi' }
    default { return 'Tarayıcı' }
  }
}

function Test-BrowserOpens {
  if ($env:DT_RECOVER -eq '1') { return $false }
  $t = Get-LaunchType
  return ($t -eq 'browser' -or $t -eq 'all')
}

function Test-DesktopAppLaunch {
  $t = Get-LaunchType
  return ($t -eq 'desktop' -or $t -eq 'all')
}

function Test-MobileAppLaunch {
  $t = Get-LaunchType
  return ($t -eq 'mobile' -or $t -eq 'all')
}

function Update-GitRepoSafe([string]$Path, [string]$Label = 'Repo') {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return $false }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
  Write-UiLine "  $DIM   $Label güncelleniyor...$RST"
  try {
    $env:GIT_TERMINAL_PROMPT = '0'
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    $cred = @('-c', 'credential.helper=')
    if ($gh) {
      & $gh.Source auth status 1>$null 2>$null
      if ($LASTEXITCODE -eq 0) { $cred = @('-c', 'credential.helper=!gh auth git-credential') }
    }
    if (Update-DuendeeFromGit -Path $Path -Cred $cred -Remote 'origin') {
      Write-UiLine "  $DIM   $Label güncel.$RST"
      return $true
    }
  } catch {}
  Write-UiLine "  $DIM   $Label mevcut haliyle kullanılacak.$RST"
  return $false
}

function Ensure-AppNpmDeps([string]$Path) {
  if (Test-Path -LiteralPath (Join-Path $Path 'node_modules\electron\package.json')) { return $true }
  Write-UiLine "  $DIM   Duendee-app bağımlılıkları kuruluyor...$RST"
  Push-Location $Path
  try {
    & npm install --omit=dev *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { & npm install *>&1 | Out-Null }
    return ($LASTEXITCODE -eq 0)
  } finally { Pop-Location }
}

function Ensure-AndroidSdkEnv {
  $ensure = Join-Path $OsDir 'scripts\ensure-android-sdk.ps1'
  if (-not (Test-Path -LiteralPath $ensure)) {
    Write-UiLine "  $RED   ensure-android-sdk.ps1 yok.$RST"
    return $null
  }
  Write-UiLine "  $DIM   Android SDK / JDK kontrol ediliyor (yoksa kurulacak)...$RST"
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ensure 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  $out | ForEach-Object { Write-UiLine "  $DIM   $_$RST" }
  if ($code -ne 0) {
    Write-UiLine "  $RED   Android SDK kurulumu başarısız.$RST"
    return $null
  }
  $javaHome = ''
  $sdkRoot = ''
  foreach ($line in @($out)) {
    $s = "$line"
    if ($s -match '^JAVA_HOME=(.+)$') { $javaHome = $Matches[1].Trim() }
    if ($s -match '^ANDROID_SDK_ROOT=(.+)$') { $sdkRoot = $Matches[1].Trim() }
  }
  if (-not $javaHome -or -not $sdkRoot) {
    Write-UiLine "  $RED   JAVA_HOME / ANDROID_SDK_ROOT okunamadı.$RST"
    return $null
  }
  return @{ JavaHome = $javaHome; SdkRoot = $sdkRoot }
}

function Write-NativeProcessLine([string]$Line) {
  if ([string]::IsNullOrWhiteSpace($Line)) { return }
  # Deprecation notes / electron-builder progress are info — not failures (pack exitCode=0).
  if ($Line -match '^(Note:|WARNING:)' -or $Line -match '^\s*[•·]' -or $Line -match '(?i)electron-builder|author is missed|duplicate dependency|no code signing|packaging\s+platform|downloaded\s+') {
    Write-UiLine ("  {0}{1}{2}" -f $DIM, $Line, $RST)
  } elseif ($Line -match '(?i)(error:|FAILED|What went wrong|Execution failed)') {
    Write-UiLine ("  {0}{1}{2}" -f $RED, $Line, $RST)
  } else {
    Write-UiLine $Line
  }
}

function Invoke-NativeProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [string]$LogPath) {
  # Reliable exit code on Windows PowerShell 5.1 (no *>&1 ErrorRecord / GetNewClosure).
  $outTemp = Join-Path $env:TEMP ("duendee-out-" + [guid]::NewGuid().ToString('n') + ".log")
  $errTemp = Join-Path $env:TEMP ("duendee-err-" + [guid]::NewGuid().ToString('n') + ".log")
  $argList = @()
  if ($ArgumentList) { $argList = @($ArgumentList) }
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $proc = Start-Process -FilePath $FilePath -ArgumentList $argList -WorkingDirectory $WorkingDirectory `
      -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $outTemp -RedirectStandardError $errTemp
    $code = 0
    if ($null -ne $proc) { $code = [int]$proc.ExitCode }
  } finally {
    $ErrorActionPreference = $prevEa
  }
  $outText = ''
  $errText = ''
  if (Test-Path -LiteralPath $outTemp) {
    $outText = Get-Content -LiteralPath $outTemp -Raw -ErrorAction SilentlyContinue
    if ($null -eq $outText) { $outText = '' }
  }
  if (Test-Path -LiteralPath $errTemp) {
    $errText = Get-Content -LiteralPath $errTemp -Raw -ErrorAction SilentlyContinue
    if ($null -eq $errText) { $errText = '' }
  }
  foreach ($line in ($outText -split '\r?\n')) { Write-NativeProcessLine $line }
  foreach ($line in ($errText -split '\r?\n')) { Write-NativeProcessLine $line }
  if ($LogPath) {
    Set-Content -LiteralPath $LogPath -Value ($outText + $errText) -Encoding UTF8
  }
  Remove-Item -LiteralPath $outTemp, $errTemp -Force -ErrorAction SilentlyContinue
  return $code
}

function Build-DuendeeAndroidApk([string]$AppDir, [hashtable]$Sdk) {
  $androidDir = Join-Path $AppDir 'android'
  $gradlew = Join-Path $androidDir 'gradlew.bat'
  if (-not (Test-Path -LiteralPath $gradlew)) {
    Write-UiLine "  $RED   gradlew.bat yok: $androidDir$RST"
    return $null
  }
  # Cap sync + Gradle both need JDK/SDK on PATH (was set too late before).
  $env:JAVA_HOME = $Sdk.JavaHome
  $env:ANDROID_SDK_ROOT = $Sdk.SdkRoot
  $env:ANDROID_HOME = $Sdk.SdkRoot
  $env:Path = "$(Join-Path $Sdk.JavaHome 'bin');$(Join-Path $Sdk.SdkRoot 'platform-tools');$env:Path"
  # Gradle local.properties wants escaped backslashes on Windows.
  $escaped = $Sdk.SdkRoot.Replace('\', '\\')
  Set-Content -LiteralPath (Join-Path $androidDir 'local.properties') -Value "sdk.dir=$escaped`n" -Encoding Ascii
  Write-UiLine "  $DIM   Capacitor android sync + DuendeeFM ikonları...$RST"
  $npxCmd = (Get-Command npx.cmd -ErrorAction SilentlyContinue)
  if (-not $npxCmd) { $npxCmd = Get-Command npx -ErrorAction SilentlyContinue }
  if (-not $npxCmd) {
    Write-UiLine "  $RED   npx bulunamadı (Node.js).$RST"
    return $null
  }
  $capLog = Join-Path $androidDir 'cap-sync.log'
  $capCode = Invoke-NativeProcess -FilePath $npxCmd.Source -ArgumentList @('--yes', 'cap', 'sync', 'android') -WorkingDirectory $AppDir -LogPath $capLog
  if ($capCode -ne 0) {
    Write-UiLine "  $RED   cap sync android başarısız (exit $capCode). Log: $capLog$RST"
    return $null
  }
  if (Test-Path -LiteralPath (Join-Path $AppDir 'scripts\sync-native-branding.mjs')) {
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nodeCmd) {
      [void](Invoke-NativeProcess -FilePath $nodeCmd.Source -ArgumentList @((Join-Path $AppDir 'scripts\sync-native-branding.mjs')) -WorkingDirectory $AppDir -LogPath $null)
    }
  }
  Write-UiLine "  $DIM   APK derleniyor (assembleDebug)...$RST"
  $gradleLog = Join-Path $androidDir 'assemble-debug.log'
  $gradleCode = Invoke-NativeProcess -FilePath $gradlew -ArgumentList @('assembleDebug', '--no-daemon') -WorkingDirectory $androidDir -LogPath $gradleLog
  $apkDir = Join-Path $androidDir 'app\build\outputs\apk\debug'
  $named = Join-Path $apkDir 'DuendeeFM.apk'
  $apk = $null
  if (Test-Path -LiteralPath $apkDir) {
    $apk = Get-ChildItem -LiteralPath $apkDir -Filter 'DuendeeFM*.apk' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) {
      $apk = Get-ChildItem -LiteralPath $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
  }
  if ($gradleCode -ne 0) {
    Write-UiLine "  $RED   Gradle assembleDebug başarısız (exit $gradleCode).$RST"
    Write-UiLine "  $DIM   Tam log: $gradleLog$RST"
    if (Test-Path -LiteralPath $gradleLog) {
      Get-Content -LiteralPath $gradleLog -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '(?i)(error:|FAILED|What went wrong|Execution failed|cannot find symbol)' } |
        Select-Object -Last 20 |
        ForEach-Object { Write-UiLine "  $RED   $_$RST" }
    }
    return $null
  }
  if (-not $apk) {
    Write-UiLine "  $RED   APK bulunamadı: $apkDir$RST"
    Write-UiLine "  $DIM   Tam log: $gradleLog$RST"
    return $null
  }
  Write-UiLine "  $GRN   BUILD SUCCESSFUL$RST"
  if ($apk.Name -ne 'DuendeeFM.apk') {
    $dest = Join-Path $apkDir 'DuendeeFM.apk'
    Copy-Item -LiteralPath $apk.FullName -Destination $dest -Force
    return (Resolve-Path -LiteralPath $dest).Path
  }
  if (Test-Path -LiteralPath $named) { return (Resolve-Path -LiteralPath $named).Path }
  return $apk.FullName
}

function Send-WhatsAppApk([string]$ApkPath, [string]$PublicUrl) {
  $waJs = Join-Path $Root 'scripts\send-whatsapp.js'
  $node = Find-NodeExe
  if (-not (Test-Path -LiteralPath $waJs) -or -not $node) {
    Write-UiLine "  $YEL   WhatsApp APK gönderimi atlandı (script/node yok).$RST"
    return
  }
  if (-not (Ensure-WhatsAppDeps)) {
    Write-UiLine "  $YEL   WhatsApp paketleri eksik; APK gönderilemedi.$RST"
    return
  }
  if (-not (Test-Path -LiteralPath $ApkPath)) {
    Write-UiLine "  $YEL   APK yok: $ApkPath$RST"
    return
  }
  Write-UiLine "  WhatsApp'a APK gönderiliyor ($([IO.Path]::GetFileName($ApkPath)))..."
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $env:DT_WA_APK = $ApkPath
    $env:DT_WA_APK_ONLY = '1'
    $env:DT_WA_PRODUCT = if ($script:ActiveProduct -eq 'duendee') { 'duendee' } else { 'fm' }
    $env:DT_WA_URL_FILE = $UrlFile
    if ($PublicUrl) { $env:DT_WA_URL = $PublicUrl }
    & $node $waJs $(if ($PublicUrl) { $PublicUrl } else { 'apk' })
    if ($LASTEXITCODE -ne 0) {
      Write-UiLine "  $YEL   WhatsApp APK gönderimi başarısız (çıkış $LASTEXITCODE).$RST"
    } else {
      Write-UiLine "  $GRN   WhatsApp $(Get-ProductDisplayName) APK gonderildi.$RST"
    }
  } finally {
    Remove-Item Env:DT_WA_APK -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_APK_ONLY -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_PRODUCT -ErrorAction SilentlyContinue
    Remove-Item Env:DT_WA_URL_FILE -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prevEa
  }
}

function Get-DesktopAppInstallDir {
  Join-Path $env:LOCALAPPDATA 'DuendeeFM'
}

function Get-DesktopAppExe {
  $dir = Get-DesktopAppInstallDir
  foreach ($name in @('DuendeeFM.exe', 'duendeefm.exe')) {
    $p = Join-Path $dir $name
    if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
  }
  return $null
}

function Get-DesktopAppStartupShortcutPath {
  Join-Path ([Environment]::GetFolderPath('Startup')) 'DuendeeFM.lnk'
}

function Get-DesktopAppDesktopShortcutPath {
  Join-Path (Get-UserDesktopPath) 'DuendeeFM.lnk'
}

function Get-DesktopAppWantedPath {
  Join-Path $StateDir 'desktop-app-wanted'
}

function Test-DesktopAppWanted {
  $p = Get-DesktopAppWantedPath
  if (Test-Path -LiteralPath $p) {
    $raw = ("$(Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction SilentlyContinue)").Trim()
    if ($raw -eq '0') { return $false }
    return $true
  }
  return (Test-Path -LiteralPath (Get-DesktopAppStartupShortcutPath))
}

function Set-DesktopAppWanted([bool]$Enable) {
  $p = Get-DesktopAppWantedPath
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  if ($Enable) {
    Set-Content -LiteralPath $p -Value '1' -Encoding Ascii
  } else {
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    [void](Set-DesktopAppAutostart $false)
  }
}

function Test-DesktopAppAutostart {
  Test-Path -LiteralPath (Get-DesktopAppStartupShortcutPath)
}

function Set-DesktopAppShortcut([string]$ExePath, [string]$LnkPath, [string]$Arguments = '') {
  if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path -LiteralPath $ExePath)) { return $false }
  try {
    $w = New-Object -ComObject WScript.Shell
    $sc = $w.CreateShortcut($LnkPath)
    $sc.TargetPath = $ExePath
    $sc.WorkingDirectory = (Split-Path -Parent $ExePath)
    $sc.Arguments = $Arguments
    $sc.WindowStyle = 1
    $sc.Description = 'DuendeeFM'
    $icoPng = Join-Path (Split-Path -Parent $ExePath) 'resources\app.asar.unpacked\electron\icon.png'
    $icoBeside = Join-Path (Split-Path -Parent $ExePath) 'DuendeeFM.exe'
    if (Test-Path -LiteralPath $icoBeside) { $sc.IconLocation = "$icoBeside,0" }
    $sc.Save()
    return $true
  } catch {
    return $false
  }
}

function Set-DesktopAppAutostart([bool]$Enable) {
  $lnk = Get-DesktopAppStartupShortcutPath
  if (-not $Enable) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $lnk)
  }
  $exe = Get-DesktopAppExe
  if (-not $exe) { return $false }
  return [bool](Set-DesktopAppShortcut -ExePath $exe -LnkPath $lnk -Arguments '')
}

function Install-DuendeeDesktopApp([string]$AppDir, [switch]$ForceRebuild) {
  $exe = Get-DesktopAppExe
  if ($exe -and -not $ForceRebuild) { return $exe }
  if (-not (Test-LooksLikeDuendeeApp $AppDir)) { return $null }
  Write-UiLine "  $DIM   DuendeeFM masaüstü app kalıcı olarak derleniyor (electron-builder)...$RST"
  $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
  if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
  if (-not $npmCmd) {
    Write-UiLine "  $RED   npm bulunamadı.$RST"
    return $null
  }
  if (-not (Ensure-AppNpmDeps $AppDir)) {
    Write-UiLine "  $RED   Duendee-app npm install başarısız.$RST"
    return $null
  }
  $packLog = Join-Path $AppDir 'electron-pack.log'
  $packCode = Invoke-NativeProcess -FilePath $npmCmd.Source -ArgumentList @('run', 'electron:pack') -WorkingDirectory $AppDir -LogPath $packLog
  if ($packCode -ne 0) {
    Write-UiLine "  $RED   Masaüstü app derlemesi başarısız (exit $packCode). Log: $packLog$RST"
    return $null
  }
  $unpacked = $null
  foreach ($cand in @(
      (Join-Path $AppDir 'dist-desktop\win-unpacked'),
      (Join-Path $AppDir 'dist-desktop\win-arm64-unpacked')
    )) {
    if (Test-Path -LiteralPath (Join-Path $cand 'DuendeeFM.exe')) { $unpacked = $cand; break }
  }
  if (-not $unpacked) {
    Write-UiLine "  $RED   Derleme çıktısı bulunamadı (win-unpacked/DuendeeFM.exe).$RST"
    return $null
  }
  $dest = Get-DesktopAppInstallDir
  if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  # Robocopy tolerates MAX_PATH and skips non-essential Capacitor android
  # build junk that Copy-Item fails on (StatusBarInfo.class deep trees).
  $robolog = Join-Path $env:TEMP 'duendee-desktop-copy.log'
  $roboArgs = @(
    $unpacked, $dest, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/nc', '/ns', '/np',
    '/R:1', '/W:1',
    '/XD', 'android', 'build', '.gradle', 'intermediates'
  )
  $robo = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $robolog
  # robocopy exit 0–7 = success / extra files; >=8 = failure
  if ($robo.ExitCode -ge 8) {
    Write-UiLine "  $YEL   Robocopy uyarı/hata (exit $($robo.ExitCode)); exe varlığı kontrol ediliyor...$RST"
  }
  $exe = Get-DesktopAppExe
  if (-not $exe) {
    # Fallback: shallow copy of essentials only (exe + resources asar)
    try {
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Copy-Item -LiteralPath (Join-Path $unpacked 'DuendeeFM.exe') -Destination (Join-Path $dest 'DuendeeFM.exe') -Force
      $resSrc = Join-Path $unpacked 'resources'
      $resDst = Join-Path $dest 'resources'
      if (Test-Path -LiteralPath $resSrc) {
        New-Item -ItemType Directory -Force -Path $resDst | Out-Null
        Get-ChildItem -LiteralPath $resSrc -Force | ForEach-Object {
          if ($_.Name -eq 'app.asar.unpacked') { return }
          Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $resDst $_.Name) -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
      $exe = Get-DesktopAppExe
    } catch {
      Write-UiLine "  $RED   Kurulum kopyası başarısız: $($_.Exception.Message)$RST"
    }
  }
  if (-not $exe) {
    Write-UiLine "  $RED   Kurulum sonrası DuendeeFM.exe bulunamadı.$RST"
    return $null
  }
  if (Test-DesktopAppWanted) {
    $deskLnk = Get-DesktopAppDesktopShortcutPath
    if (Set-DesktopAppShortcut -ExePath $exe -LnkPath $deskLnk) {
      Write-UiLine "  $GRN   Masaüstü kısayolu: $deskLnk$RST"
    } else {
      Write-UiLine "  $YEL   Masaüstü kısayolu oluşturulamadı.$RST"
    }
    [void](Set-DesktopAppAutostart $true)
  }
  Write-UiLine "  $GRN   DuendeeFM kuruldu: $exe$RST"
  return $exe
}

function Write-DesktopAppPid([int]$ProcessId) {
  if ($ProcessId -le 0) { return }
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Set-Content -LiteralPath $DesktopAppPidFile -Value $ProcessId -Encoding Ascii
}

function Read-DesktopAppPid {
  if (-not (Test-Path -LiteralPath $DesktopAppPidFile)) { return $null }
  $raw = ("$(Get-Content -LiteralPath $DesktopAppPidFile -TotalCount 1 -ErrorAction SilentlyContinue)").Trim()
  $n = 0
  if ([int]::TryParse($raw, [ref]$n) -and $n -gt 0) { return $n }
  return $null
}

function Stop-DuendeeDesktopAppProcesses {
  $stopped = $false
  $pidSaved = Read-DesktopAppPid
  if ($pidSaved -and (Test-PidAlive $pidSaved)) {
    Stop-ProcessTree $pidSaved
    $stopped = $true
  }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $n = [string]$_.Name
    $ep = [string]$_.ExecutablePath
    ($n -ieq 'DuendeeFM.exe') -or ($ep -match '(?i)\\DuendeeFM(\\|$)') -or ($ep -match '(?i)\\DuendeeFM\.exe$')
  } | ForEach-Object {
    if ($_.ProcessId) {
      Stop-ProcessTree ([int]$_.ProcessId)
      $stopped = $true
    }
  }
  # Dev fallback: electron launched from Duendee-app for tunnel mode
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $cmd = [string]$_.CommandLine
    $cmd -match '(?i)electron' -and $cmd -match '(?i)Duendee-app' -and $cmd -match '(?i)electron:(tunnel|local|dev)?'
  } | ForEach-Object {
    if ($_.ProcessId) {
      Stop-ProcessTree ([int]$_.ProcessId)
      $stopped = $true
    }
  }
  Remove-Item -LiteralPath $DesktopAppPidFile -Force -ErrorAction SilentlyContinue
  return $stopped
}

function Remove-DuendeeDesktopAppInstall {
  # Tunnel cancel [4]: close app and delete permanent install + shortcuts (like stopping the tunnel).
  $had = Stop-DuendeeDesktopAppProcesses
  $dest = Get-DesktopAppInstallDir
  if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    $had = $true
  }
  Remove-Item -LiteralPath (Get-DesktopAppDesktopShortcutPath) -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Get-DesktopAppStartupShortcutPath) -Force -ErrorAction SilentlyContinue
  if ($had) {
    Write-UiLine "  $DIM   DuendeeFM masaüstü app kapatıldı ve kurulum silindi.$RST"
  }
}

function Start-DuendeeDesktopApp([string]$AppDir, [string]$TunnelUrl) {
  # Pack after tunnel is up (not from [5] menu). Rebuild when missing or sources newer.
  $force = $false
  $existing = Get-DesktopAppExe
  if ($existing) {
    foreach ($src in @(
        (Join-Path $AppDir 'www\sync-meta.json'),
        (Join-Path $AppDir 'electron\main.cjs'),
        (Join-Path $AppDir 'package.json')
      )) {
      if (-not (Test-Path -LiteralPath $src)) { continue }
      try {
        if ((Get-Item -LiteralPath $src).LastWriteTimeUtc -gt (Get-Item -LiteralPath $existing).LastWriteTimeUtc) {
          $force = $true
          break
        }
      } catch {}
    }
  }
  $exe = Install-DuendeeDesktopApp -AppDir $AppDir -ForceRebuild:$force
  if ($exe -and (Test-DesktopAppWanted)) {
    [void](Set-DesktopAppShortcut -ExePath $exe -LnkPath (Get-DesktopAppDesktopShortcutPath))
    [void](Set-DesktopAppAutostart $true)
  }
  if ($exe) {
    Write-UiLine "  $GRN   Masaüstü app (DuendeeFM) açılıyor (tool terminalinden bağımsız)...$RST"
    # Local packaged UI — tunnel URL as start page rendered empty/black in Electron.
    $envMap = @{ DUENDEE_START_MODE = 'local' }
    if ($TunnelUrl) {
      $envMap['DUENDEE_TUNNEL_URL'] = $TunnelUrl
    }
    $appPid = Start-DetachedGuiWithEnv -FileName $exe -WorkingDirectory (Split-Path -Parent $exe) -Environment $envMap
    if ($appPid) {
      Write-DesktopAppPid $appPid
      return $true
    }
    Write-UiLine "  $RED   DuendeeFM başlatılamadı (detached).$RST"
  }
  Write-UiLine "  $YEL   Kalıcı paket yok/başarısız; geliştirme Electron deneniyor...$RST"
  $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
  if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
  if (-not $npmCmd) {
    Write-UiLine "  $RED   npm bulunamadı.$RST"
    return $false
  }
  $envMap = @{
    DUENDEE_TUNNEL_URL = "$TunnelUrl"
    DUENDEE_START_MODE = 'local'
  }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($key in $envMap.Keys) {
    $val = ([string]$envMap[$key]).Replace("'", "''")
    [void]$parts.Add("`$env:$key='$val'")
  }
  $wdLit = $AppDir.Replace("'", "''")
  [void]$parts.Add("Set-Location -LiteralPath '$wdLit'")
  [void]$parts.Add("npm run electron:local")
  $script = ($parts -join '; ')
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $launcher = Start-HiddenCmd "`"$ps`" -NoProfile -WindowStyle Hidden -EncodedCommand $b64"
  if ($launcher -and $launcher.Id) {
    Write-DesktopAppPid ([int]$launcher.Id)
    return $true
  }
  Write-UiLine "  $RED   Electron başlatılamadı.$RST"
  return $false
}

function Start-CompanionApps([string]$TunnelUrl) {
  $script:LastMobileApkSent = $false
  $wantDesktop = Test-DesktopAppLaunch
  $wantMobile = Test-MobileAppLaunch
  if (-not $wantDesktop -and -not $wantMobile) { return }
  if ([string]::IsNullOrWhiteSpace($TunnelUrl) -or $TunnelUrl -notmatch '^https://') {
    Write-UiLine "  $YEL   Masaüstü/mobil app için geçerli tünel URL'si yok.$RST"
    return
  }
  $path = $AppPath
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-LooksLikeDuendeeApp $path)) {
    $path = Resolve-DuendeeAppPath -Preferred $AppPath -Project $Project
  }
  if (-not (Test-LooksLikeDuendeeApp $path)) {
    Write-UiLine "  $YEL   Duendee-app bulunamadı. config.json içine appPath yazın.$RST"
    return
  }
  $script:AppPath = $path
  Write-UiLine "  $DIM   Duendee-app: $path$RST"
  [void](Update-GitRepoSafe $path 'Duendee-app')
  if (-not (Ensure-AppNpmDeps $path)) {
    Write-UiLine "  $RED   Duendee-app npm install başarısız.$RST"
    return
  }
  $dist = Join-Path $Project 'dist'
  $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
  if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
  if (-not $npmCmd) {
    Write-UiLine "  $RED   npm bulunamadı.$RST"
    return
  }
  $syncArgs = if (Test-Path -LiteralPath (Join-Path $dist 'index.html')) {
    Write-UiLine "  $DIM   Duendee-app www senkronu (mevcut dist)...$RST"
    @('run', 'sync:skip-build')
  } else {
    Write-UiLine "  $DIM   Duendee-app www senkronu (build)...$RST"
    @('run', 'sync')
  }
  $syncLog = Join-Path $path 'sync-web.log'
  $syncCode = Invoke-NativeProcess -FilePath $npmCmd.Source -ArgumentList $syncArgs -WorkingDirectory $path -LogPath $syncLog
  if ($syncCode -ne 0) {
    Write-UiLine "  $RED   Duendee-app sync başarısız (exit $syncCode). Log: $syncLog$RST"
    return
  }

  if ($wantDesktop) {
    [void](Start-DuendeeDesktopApp -AppDir $path -TunnelUrl $TunnelUrl)
  }

  if ($wantMobile) {
    Write-UiLine "  $GRN   Mobil app güncel repodan APK olarak derleniyor...$RST"
    $sdk = Ensure-AndroidSdkEnv
    if (-not $sdk) { return }
    $apk = Build-DuendeeAndroidApk -AppDir $path -Sdk $sdk
    if (-not $apk) { return }
    Write-UiLine "  $GRN   APK hazır: $apk$RST"
    Send-WhatsAppApk -ApkPath $apk -PublicUrl $TunnelUrl
    $script:LastMobileApkSent = $true
  }
}

function Invoke-Autostart {
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$C5   --- Cihaz Açılışında Otomatik Başlat ---$RST"
  Write-UiLine ''
  $mode = Get-AutoMode
  switch ($mode) {
    'tool' { Write-UiLine "  $DIM   Tool:$RST $GRN$BOLD[TOOL]$RST" }
    'tunnel' { Write-UiLine "  $DIM   Tool:$RST $GRN$BOLD[TOOL+TÜNEL]$RST" }
    default { Write-UiLine "  $DIM   Tool:$RST $RED$BOLD[KAPALI]$RST" }
  }
  $appWanted = Test-DesktopAppWanted
  if ($appWanted) {
    Write-UiLine "  $DIM   Masaüstü App:$RST $GRN$BOLD[BAŞLANGIÇTA+KISAYOL]$RST"
  } else {
    Write-UiLine "  $DIM   Masaüstü App:$RST $RED$BOLD[KAPALI]$RST"
  }
  $launch = Get-LaunchType
  Write-UiLine "  $DIM   Derleme/Başlatma Tipi:$RST $GRN$BOLD[$(Get-LaunchTypeLabel $launch)]$RST"
  Write-UiLine ''
  Write-UiLine "  [T]  Yalnızca tool'u otomatik başlat"
  Write-UiLine "  [S]  Tool'u ve tünel servisini otomatik başlat"
  Write-UiLine "  [A]  Masaüstü App: kalıcı kurulum + masaüstü kısayolu + başlangıç$(if ($appWanted) { "  $GRN[AÇIK]$RST" } else { '' })"
  Write-UiLine "  $DIM       (Derleme [1] tünel açılınca yapılır)$RST"
  Write-UiLine ''
  Write-UiLine "  $DIM--- Derleme/Başlatma Tipi ---$RST"
  Write-UiLine "  [1]  Tarayıcı$(if ($launch -eq 'browser') { "  $GRN[SEÇİLİ]$RST" } else { '' })"
  Write-UiLine "  [2]  Masaüstü App$(if ($launch -eq 'desktop') { "  $GRN[SEÇİLİ]$RST" } else { '' })"
  Write-UiLine "  [3]  Mobil App$(if ($launch -eq 'mobile') { "  $GRN[SEÇİLİ]$RST" } else { '' })"
  Write-UiLine "  [4]  Hepsi$(if ($launch -eq 'all') { "  $GRN[SEÇİLİ]$RST" } else { '' })"
  if ($mode -ne 'off' -or $appWanted) {
    Write-UiLine "  [K]  Tool otomatik başlatmayı kapat"
  }
  Write-UiLine "  $DIM$BOLD[X]$RST  ${DIM}Geri dön$RST"
  Write-UiLine ''
  $choices = if ($mode -ne 'off' -or $appWanted) { 'TSA1234KX' } else { 'TSA1234X' }
  Write-Ui "$DIM   Seçim: $RST"
  $c = Get-Choice $choices
  Write-UiLine ''
  if ($c -eq 'X') { return }
  if ($c -eq 'A') {
    if ($appWanted) {
      Set-DesktopAppWanted $false
      Write-UiLine "  $RED   DuendeeFM başlangıç/kısayol tercihi kapatıldı.$RST"
      Write-UiLine "  $DIM   (Mevcut masaüstü kısayolu duruyor; başlangıç kaydı silindi.)$RST"
    } else {
      Set-DesktopAppWanted $true
      Write-UiLine "  $GRN   DuendeeFM: tünel [1] açılınca kalıcı derlenecek, kısayol + başlangıç eklenecek.$RST"
      if (Get-DesktopAppExe) {
        $exe = Get-DesktopAppExe
        [void](Set-DesktopAppShortcut -ExePath $exe -LnkPath (Get-DesktopAppDesktopShortcutPath))
        [void](Set-DesktopAppAutostart $true)
        Write-UiLine "  $DIM   Mevcut kurulum bulundu; kısayol ve başlangıç şimdi güncellendi.$RST"
      }
    }
    Complete-Action
    return
  }
  if ($c -in @('1', '2', '3', '4')) {
    $next = switch ($c) {
      '1' { 'browser' }
      '2' { 'desktop' }
      '3' { 'mobile' }
      default { 'all' }
    }
    if ($next -eq $launch) {
      Write-UiLine "  $DIM   Bu derleme/başlatma tipi zaten seçili.$RST"
    } else {
      Set-LaunchType $next
      Write-UiLine "  $GRN   Derleme/Başlatma Tipi: $(Get-LaunchTypeLabel $next)$RST"
      Write-UiLine "  $DIM   Tünel her başlatıldığında bu seçim uygulanacak.$RST"
      if ($next -eq 'desktop' -or $next -eq 'all') {
        Write-UiLine "  $DIM   Kalıcı app derlemesi tünel [1] açılınca yapılır.$RST"
      }
    }
    Complete-Action
    return
  }
  $target = switch ($c) {
    'T' { 'tool' }
    'S' { 'tunnel' }
    default { 'off' }
  }
  if ($target -eq $mode) {
    Write-UiLine "  $DIM   Bu ayar zaten seçili.$RST"
    Complete-Action
    return
  }
  $ok = Set-AutoMode $target
  if ($ok) {
    switch ($target) {
      'tool' { Write-UiLine "  $GRN   Yalnızca tool otomatik başlayacak.$RST" }
      'tunnel' { Write-UiLine "  $GRN   Tool ve tünel servisi otomatik başlayacak.$RST" }
      default { Write-UiLine "  $RED   Tool otomatik başlatma kapatıldı.$RST" }
    }
    if ($target -ne 'off') {
      Write-UiLine "  $DIM   Kayıt: Başlangıç klasörü - Duendee Tunnel Tool$RST"
    }
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
      Write-UiLine "  $DIM   $name kaldırılamadı. Yönetici onayı gerekebilir.$RST"
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
    Write-UiLine "  $DIM   Node.js hâlâ duruyor: $($nodeCmd.Source)$RST"
    Write-UiLine "  $DIM   Yönetici PowerShell ile tekrar deneyin veya Windows Ayarlar > Uygulamalar üzerinden kaldırın.$RST"
  } else {
    Write-UiLine "  $GRN   Node.js bu oturumda artık yok.$RST"
  }
  if (Find-Cloudflared) {
    Write-UiLine "  $DIM   cloudflared hâlâ duruyor: $(Find-Cloudflared)$RST"
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
    [void]$lines.Add('Node.js')
    [void]$lines.Add('cloudflared')
  }
  return $lines
}

function Invoke-Uninstall {
  param([string]$Mode = '')
  Clear-Host
  Initialize-Utf8Console
  Write-UiLine ''
  Write-UiLine "$C6   --- Aracı Kaldır ---$RST"
  Write-UiLine ''
  if ($Mode -notin @('1', '2')) {
    Write-UiLine "  [1]  Yalnızca Duendee Tunnel Tool"
    Write-UiLine "  [2]  Tool, Node.js ve cloudflared"
    Write-UiLine "  $DIM$BOLD[X]$RST  ${DIM}Vazgeç$RST"
    Write-UiLine ''
    Write-Ui "$DIM   Seçim [1/2/X]: $RST"
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
  Write-Ui "$DIM   [E] Evet, kaldır    [H] Hayır: $RST"
  $yes = Get-Choice 'EH'
  Write-UiLine $yes
  if ($yes -ne 'E') {
    Write-UiLine ''
    Write-UiLine "  $DIM   Kaldırma iptal edildi.$RST"
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
  Write-UiLine "$C4   --- Tüm terminaller kapatılıyor ---$RST"
  $fleetRole = "$(Invoke-Fleet role)".Trim()
  if ($fleetRole -eq 'other') {
    Write-UiLine "  ${RED}   Aktif tünel kapatılıyor...$RST"
    [void](Invoke-Fleet stop)
    if ($script:FleetExit -eq 0) {
      Invoke-RetractWhatsApp
      Write-UiLine "  $RED   Tünel servisi kapatıldı. Çıkılıyor...$RST"
    } else {
      Write-UiLine "  $RED$BOLD[HATA]$RST Tünel servisi kapatılamadı."
    }
    Write-UiLine ''
    exit 0
  }
  Invoke-RetractWhatsApp
  Stop-AllToolProcesses
  Invoke-FleetRelease
  Write-UiLine "  $RED   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...$RST"
  Write-UiLine ''
  exit 0
}

# Closing the tool window leaves the tunnel, the app origin, and the link message.
# [4] stops the tunnel.
$script:CleanupDone = $false
function Invoke-ExitCleanup {
  if ($script:CleanupDone) { return }
  $script:CleanupDone = $true
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
}

try {
  if ($script:UninstallCli) {
    $script:CleanupDone = $true
    Invoke-Uninstall -Mode $UninstallChoice
    exit 0
  }
  Ensure-RuntimeRequirements
  Update-ToolCopy
  if ($script:BootTunnel) {
    Invoke-Start
  }
  switch ($Action) {
    '1' { Invoke-Start; exit 0 }
    '2' { Invoke-Status; exit 0 }
    '3' { Invoke-CopyLink; exit 0 }
    '4' { Invoke-Cancel; exit 0 }
    '5' { Invoke-Autostart; exit 0 }
    'recover-tunnel' {
      if (Test-Path -LiteralPath (Join-Path $StateDir 'manual-stop')) { exit 0 }
      Invoke-Start
      exit 0
    }
    'start-origin' {
      if (Start-AppOrigin) { exit 0 }
      exit 1
    }
  }

  while ($true) {
    Show-RootMenu
    $product = Get-Choice '12X'
    Write-UiLine ''
    if ($product -eq 'X') {
      Invoke-ExitCleanup
      exit 0
    }
    if ($product -eq '1') {
      Bind-ProductState 'fm'
      while ($true) {
        Show-Menu
        $choice = Get-Choice '123456B'
        Write-UiLine ''
        if ($choice -eq 'B') { break }
        try {
          switch ($choice) {
            '1' { Invoke-Start }
            '2' { Invoke-Status }
            '3' { Invoke-CopyLink }
            '4' { Invoke-Cancel }
            '5' { Invoke-Autostart }
            '6' { Invoke-Uninstall }
          }
        } catch {
          Write-UiLine "  $RED$BOLD[HATA]$RST $($_.Exception.Message)"
          Complete-Action
        }
      }
      continue
    }
    if ($product -eq '2') {
      Bind-ProductState 'duendee'
      [void](Ensure-NeoDuendeeAutoDetect)
      Bind-ProductState 'duendee'
      if ([string]::IsNullOrWhiteSpace($script:DuendeeProject) -or -not (Test-Path -LiteralPath $script:DuendeeProject)) {
        Write-UiLine "  $RED$BOLD[HATA]$RST Duendee-main otomatik bulunamadı."
        Write-UiLine "  $DIM   Beklenen yol: ...\YEK\Cursor\Duendee-main (veya DT_NEO_DUENDEE_DIR)$RST"
        Complete-Action
        continue
      }
      while ($true) {
        Show-DuendeeMenu
        $choice = Get-Choice '123456B'
        Write-UiLine ''
        if ($choice -eq 'B') { break }
        try {
          switch ($choice) {
            '1' { Invoke-Start }
            '2' { Invoke-StartDuendeeDevServer }
            '3' { Invoke-Status }
            '4' { Invoke-CopyLink }
            '5' { Invoke-Cancel }
            '6' { Invoke-StopDuendeeDevServer }
          }
        } catch {
          Write-UiLine "  $RED$BOLD[HATA]$RST $($_.Exception.Message)"
          Complete-Action
        }
      }
    }
  }
} finally {
  # Window close / normal exit path — watcher covers hard kills
  Invoke-ExitCleanup
}

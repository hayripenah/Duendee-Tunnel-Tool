#Requires -Version 5.1
# Install Duendee Tunnel Tool portable (Windows) and add `duendee-tunnel` to PATH.
# Usage (one-liner):
#   irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex
[CmdletBinding()]
param(
  [string]$Repo = 'hayripenah/Duendee-Tunnel-Tool',
  [string]$Tag = 'latest',
  [string]$InstallDir = '',
  [switch]$NoDesktopShortcut,
  [switch]$SkipNpm
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Join-Path $env:LOCALAPPDATA 'DuendeeTunnelTool'
}
$BinDir = Join-Path $InstallDir 'bin'
$AssetName = 'Duendee-Tunnel-Tool-Windows-portable.zip'

function Get-ReleaseAssetUrl {
  param([string]$Repository, [string]$ReleaseTag, [string]$Name)
  if ($ReleaseTag -eq 'latest') {
    $api = "https://api.github.com/repos/$Repository/releases/latest"
  } else {
    $api = "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
  }
  $headers = @{ 'User-Agent' = 'DuendeeTunnelTool-Install'; 'Accept' = 'application/vnd.github+json' }
  $rel = Invoke-RestMethod -Uri $api -Headers $headers
  $asset = $rel.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $asset) { throw "Release asset not found: $Name (tag=$($rel.tag_name))" }
  return @{ Url = $asset.browser_download_url; Tag = $rel.tag_name }
}

function Invoke-NpmInstallSafe {
  param([string]$WorkDir)
  # npm.ps1 surfaces "npm warn ..." on stderr as NativeCommandError; with Stop that aborts
  # before shim/PATH. Always run via cmd + npm.cmd and Continue.
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevNative = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  $ec = 1
  try {
    Push-Location $WorkDir
    try {
      Write-Host "npm install..."
      & cmd.exe /c "npm.cmd install --omit=dev"
      $ec = $LASTEXITCODE
      if ($ec -ne 0) {
        & cmd.exe /c "npm.cmd install"
        $ec = $LASTEXITCODE
      }
    } finally {
      Pop-Location
    }
  } finally {
    $ErrorActionPreference = $prevEa
    if ($null -ne $prevNative) {
      $PSNativeCommandUseErrorActionPreference = $prevNative
    }
  }
  if ($ec -ne 0) {
    throw "npm install basarisiz (cikis $ec). Ag/proxy veya Node kurulumunu kontrol edin."
  }
  $baileys = Join-Path $WorkDir 'node_modules\@whiskeysockets\baileys\package.json'
  if (-not (Test-Path -LiteralPath $baileys)) {
    throw "WhatsApp bagimliligi eksik (baileys). Tekrar: npm install  (in $WorkDir)"
  }
}

function Test-InstallInteractive {
  if ($env:CI -or $env:DT_SKIP_GH_AUTH -eq '1') { return $false }
  try { return [Environment]::UserInteractive } catch { return $true }
}

function Find-InstallNode {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $local = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\node') -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($local) { return $local.FullName }
  foreach ($c in @(
      (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

function Find-InstallCloudflared {
  $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cfExe = Join-Path $env:USERPROFILE '.cloudflared\cloudflared.exe'
  if (Test-Path -LiteralPath $cfExe) { return $cfExe }
  return $null
}

function Find-InstallGh {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $exe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\gh') -Filter gh.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($exe) { return $exe.FullName }
  return $null
}

function Assert-CoreRuntime {
  param([string]$WorkDir)
  if (-not (Find-InstallNode)) {
    throw 'Node.js yok. Kurulum Node indirmeyi basaramadi.'
  }
  if (-not (Find-InstallCloudflared)) {
    throw 'cloudflared yok. Kurulum cloudflared indirmeyi basaramadi.'
  }
  if (-not (Find-InstallGh)) {
    throw 'GitHub CLI (gh) yok. Kurulum gh indirmeyi basaramadi.'
  }
  $baileys = Join-Path $WorkDir 'node_modules\@whiskeysockets\baileys\package.json'
  if (-not (Test-Path -LiteralPath $baileys)) {
    throw "WhatsApp bagimliliklari eksik. Calistirin: npm install  (in $WorkDir)"
  }
}

function Ensure-GitHubLogin {
  $gh = Find-InstallGh
  if (-not $gh) { throw 'GitHub CLI (gh) bulunamadi.' }
  $envTok = (($env:GH_TOKEN, $env:GITHUB_TOKEN) | Where-Object { $_ } | Select-Object -First 1)
  if ($envTok) {
    Write-Host "GitHub: GH_TOKEN / GITHUB_TOKEN kullanilacak."
    return
  }
  & $gh auth status 1>$null 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "GitHub: gh oturumu hazir."
    return
  }
  if (-not (Test-InstallInteractive)) {
    Write-Host "UYARI: GitHub girisi yok. Yerel tunel calisir; filo ve private clone icin sonra: gh auth login"
    Write-Host "        veya GH_TOKEN / GITHUB_TOKEN ortam degiskeni verin."
    return
  }
  Write-Host "GitHub girisi gerekli (filo + private repo). Tarayici acilacak..."
  & $gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) {
    Write-Host "UYARI: GitHub girisi tamamlanmadi. Yerel tunel yine de calisir."
    Write-Host "        Filo / private clone icin: gh auth login"
  }
}

function Invoke-InstallDoctor {
  param([string]$WorkDir)
  $tool = Join-Path $WorkDir 'windows\duendee-tunnel-tool.ps1'
  if (-not (Test-Path -LiteralPath $tool)) {
    throw "doctor calistirilamadi: $tool yok"
  }
  if (-not (Select-String -LiteralPath $tool -Pattern 'function Invoke-Doctor' -Quiet)) {
    Write-Host "UYARI: Bu paket henuz 'doctor' icermiyor; Assert-CoreRuntime ile dogrulandi."
    return
  }
  Write-Host ""
  Write-Host "Kurulum dogrulaniyor (doctor)..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool doctor
  if ($LASTEXITCODE -eq 1) {
    throw "Doctor basarisiz (zorunlu bagimliliklar eksik). Yukaridaki hatalari duzeltip kurunumu tekrarlayin."
  }
}

function Install-ShimAndUserPath {
  param([string]$Root, [string]$Bin)

  New-Item -ItemType Directory -Force -Path $Bin | Out-Null
  $shimCmd = Join-Path $Bin 'duendee-tunnel.cmd'
  $shimPs1 = Join-Path $Bin 'duendee-tunnel.ps1'

  $cmdShim = @(
    '@echo off',
    'setlocal',
    'set "TOOL_ROOT=%~dp0.."',
    'cd /d "%TOOL_ROOT%"',
    'call "%TOOL_ROOT%\windows\Duendee Tunnel Tool.bat" %*'
  ) -join "`r`n"
  Set-Content -Path $shimCmd -Value $cmdShim -Encoding ASCII

  # Avoid expandable here-strings eating %~dp0 / $vars; write literal lines
  # Explicit param so `duendee-tunnel uninstall` and `duendee-tunnel uninstall 2` reach the tool.
  $psShim = "#Requires -Version 5.1`r`n" +
    'param(' + "`r`n" +
    '  [Parameter(Position = 0)]' + "`r`n" +
    '  [string]$Action = '''',' + "`r`n" +
    '  [Parameter(Position = 1)]' + "`r`n" +
    '  [string]$Choice = ''''' + "`r`n" +
    ')' + "`r`n" +
    '$Root = Split-Path -Parent $PSScriptRoot' + "`r`n" +
    '$tool = Join-Path $Root ''windows\duendee-tunnel-tool.ps1''' + "`r`n" +
    'if ($Action) { & $tool $Action $Choice } else { & $tool }' + "`r`n"
  Set-Content -Path $shimPs1 -Value $psShim -Encoding UTF8

  # Also drop a shim into WindowsApps (often already on User PATH) as a belt-and-suspenders fallback
  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  if (Test-Path $windowsApps) {
    $waShim = Join-Path $windowsApps 'duendee-tunnel.cmd'
    $waBody = @(
      '@echo off',
      'call "%LOCALAPPDATA%\DuendeeTunnel\launch.cmd" %*'
    ) -join "`r`n"
    Set-Content -Path $waShim -Value $waBody -Encoding ASCII
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
  $changed = $false
  if ($parts -notcontains $Bin) {
    $newPath = if ($userPath.TrimEnd(';')) { "$userPath;$Bin" } else { $Bin }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $changed = $true
    Write-Host "Added to user PATH: $Bin"
  } else {
    Write-Host "User PATH already contains: $Bin"
  }

  # Current process: irm|iex runs in this session — prepend so `duendee-tunnel` works next
  $envParts = @($env:Path -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
  if ($envParts -notcontains $Bin) {
    $env:Path = "$Bin;$env:Path"
  } else {
    # Move bin to the front for this session
    $rest = ($envParts | Where-Object { $_ -ne $Bin }) -join ';'
    $env:Path = if ($rest) { "$Bin;$rest" } else { $Bin }
  }
  if ($windowsApps -and (Test-Path -LiteralPath (Join-Path $windowsApps 'duendee-tunnel.cmd'))) {
    if ($env:Path -notlike "*${windowsApps}*") {
      $env:Path = "$windowsApps;$env:Path"
    }
  }

  if (-not (Test-Path -LiteralPath $shimCmd)) {
    throw "Failed to create shim: $shimCmd"
  }

  return @{ Shim = $shimCmd; PathChanged = $changed; BinDir = $Bin }
}

function Stop-RunningTool {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and (
      $_.CommandLine -like '*duendee-tunnel-tool.ps1*' -or
      $_.CommandLine -like '*Duendee Tunnel Tool.bat*' -or
      $_.CommandLine -like '*DuendeeTunnel\launch.ps1*'
    )
  } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Copy-ToolTree([string]$Source, [string]$Dest) {
  $root = $Source.TrimEnd('\')
  Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length).TrimStart('\')
    if ($rel -match '(?i)^(\.git|node_modules|dist)\\' -or $rel -match '(?i)\\(\.git|node_modules|dist)\\') { return }
    $target = Join-Path $Dest $rel
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function Get-ToolTree([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return $null }
  $portable = Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Duendee-Tunnel-Tool-Windows-portable*' } |
    Select-Object -First 1
  if ($portable -and (Test-Path -LiteralPath (Join-Path $portable.FullName 'windows\duendee-tunnel-tool.ps1'))) {
    return $portable
  }
  foreach ($cand in @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $cand.FullName 'windows\duendee-tunnel-tool.ps1')) {
      return $cand
    }
  }
  return $null
}

Write-Host "Installing Duendee Tunnel Tool -> $InstallDir"

$info = Get-ReleaseAssetUrl -Repository $Repo -ReleaseTag $Tag -Name $AssetName
$tmp = Join-Path $env:TEMP ("duendee-tunnel-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp $AssetName
$shimInfo = $null

try {
  Write-Host "Downloading $($info.Tag): $($info.Url)"
  Invoke-WebRequest -Uri $info.Url -OutFile $zip -UseBasicParsing

  Stop-RunningTool
  Start-Sleep -Milliseconds 400
  if (Test-Path $InstallDir) {
    # Keep user config/session if present
    $keep = @{}
    foreach ($name in @('config.json', '.whatsapp-session', '.tunnelstate', '.tunnelstate-duendee')) {
      $p = Join-Path $InstallDir $name
      if (Test-Path $p) {
        $bak = Join-Path $tmp ("keep-" + $name.Replace('.', '_'))
        Copy-Item $p $bak -Recurse -Force
        $keep[$name] = $bak
      }
    }
    Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object {
      $_.Name -notin @('config.json', '.whatsapp-session', '.tunnelstate', '.tunnelstate-duendee', 'bin', 'node_modules')
    } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $keep = @{}
  }

  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $extracted = Get-ToolTree $tmp
  $hasStable = $extracted -and (Test-Path -LiteralPath (Join-Path $extracted.FullName 'windows\stable-launch.ps1'))
  if (-not $hasStable) {
    Write-Host "Güncel sürüm indiriliyor..."
    $mainZip = Join-Path $tmp 'main.zip'
    Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/main.zip" -OutFile $mainZip -UseBasicParsing
    $mainDir = Join-Path $tmp 'main-src'
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Expand-Archive -Path $mainZip -DestinationPath $mainDir -Force
    $extracted = Get-ToolTree $mainDir
  }
  if (-not $extracted) { throw 'Zip layout unexpected (windows tool missing).' }

  $cmdPath = $MyInvocation.MyCommand.Path
  if ($cmdPath) {
    $localRoot = Split-Path -Parent (Split-Path -Parent $cmdPath)
    $localPs1 = Join-Path $localRoot 'windows\duendee-tunnel-tool.ps1'
    if ((Test-Path -LiteralPath $localPs1) -and (Select-String -LiteralPath $localPs1 -Pattern 'Invoke-Uninstall' -Quiet)) {
      $extracted = Get-Item -LiteralPath $localRoot
      Write-Host "Using local repo: $localRoot"
    }
  }

  Copy-ToolTree -Source $extracted.FullName -Dest $InstallDir

  foreach ($k in $keep.Keys) {
    $dest = Join-Path $InstallDir $k
    if (-not (Test-Path $dest)) {
      Copy-Item $keep[$k] $dest -Recurse -Force
    }
  }

  $cfgEx = Join-Path $InstallDir 'config.example.json'
  $cfg = Join-Path $InstallDir 'config.json'
  $installedPs1 = Join-Path $InstallDir 'windows\duendee-tunnel-tool.ps1'
  if (-not (Select-String -LiteralPath $installedPs1 -Pattern 'Invoke-Uninstall' -Quiet)) {
    throw "Installed menu is still missing option 7: $installedPs1"
  }
  if (-not (Test-Path $cfgEx)) { throw 'Portable zip missing config.example.json' }
  if (-not (Test-Path $cfg)) {
    Copy-Item $cfgEx $cfg -Force
    Write-Host "config.json oluşturuldu."
  }

  $nodeZip = Join-Path $tmp 'node-win.zip'
  $nodeHome = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\node'
  if (-not (Find-InstallNode)) {
    Write-Host "Node.js kuruluyor..."
    try {
      Invoke-WebRequest -Uri 'https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip' -OutFile $nodeZip -UseBasicParsing
      if (Test-Path $nodeHome) { Remove-Item $nodeHome -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $nodeHome | Out-Null
      Expand-Archive -Path $nodeZip -DestinationPath $nodeHome -Force
      $nodeBin = Get-ChildItem $nodeHome -Directory | Select-Object -First 1
      if ($nodeBin) { $env:Path = "$($nodeBin.FullName);$env:Path" }
    } catch {
      throw "Node.js indirilemedi: $($_.Exception.Message)"
    }
  }
  if (-not (Find-InstallNode)) {
    throw 'Node.js kurulduktan sonra bulunamadi.'
  }

  $cfExe = Join-Path $env:USERPROFILE '.cloudflared\cloudflared.exe'
  if (-not (Find-InstallCloudflared)) {
    Write-Host "cloudflared kuruluyor..."
    try {
      New-Item -ItemType Directory -Force -Path (Split-Path $cfExe) | Out-Null
      $cfArch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
      Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$cfArch.exe" -OutFile $cfExe -UseBasicParsing
    } catch {
      throw "cloudflared indirilemedi: $($_.Exception.Message)"
    }
  }
  if (-not (Find-InstallCloudflared)) {
    throw 'cloudflared kurulduktan sonra bulunamadi.'
  }

  if (-not (Find-InstallGh)) {
    Write-Host "GitHub CLI kuruluyor..."
    try {
      $ghVer = '2.102.0'
      $ghArch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
      $ghZip = Join-Path $tmp "gh-$ghVer.zip"
      $ghHome = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel\gh'
      Invoke-WebRequest -Uri "https://github.com/cli/cli/releases/download/v$ghVer/gh_${ghVer}_windows_${ghArch}.zip" -OutFile $ghZip -UseBasicParsing
      if (Test-Path $ghHome) { Remove-Item $ghHome -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $ghHome | Out-Null
      Expand-Archive -Path $ghZip -DestinationPath $ghHome -Force
      $ghExe = Get-ChildItem $ghHome -Filter gh.exe -Recurse | Select-Object -First 1
      if ($ghExe) { $env:Path = "$(Split-Path $ghExe.FullName);$env:Path" }
    } catch {
      throw "GitHub CLI indirilemedi: $($_.Exception.Message)"
    }
  }
  if (-not (Find-InstallGh)) {
    throw 'GitHub CLI (gh) kurulduktan sonra bulunamadi.'
  }

  if (-not $SkipNpm) {
    if (-not ((Get-Command npm.cmd -ErrorAction SilentlyContinue) -or (Get-Command npm -ErrorAction SilentlyContinue))) {
      throw "npm bulunamadi. Node.js PATH'te olmali; sonra: npm install  (in $InstallDir)"
    }
    Invoke-NpmInstallSafe -WorkDir $InstallDir
  }

  Assert-CoreRuntime -WorkDir $InstallDir
} finally {
  # Shim + PATH even when body throws (so a partial install is still launchable after fix)
  try {
    $shimInfo = Install-ShimAndUserPath -Root $InstallDir -Bin $BinDir
  } catch {
    Write-Host "HATA: shim/PATH kurulamadi: $($_.Exception.Message)"
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$stableDir = Join-Path $env:LOCALAPPDATA 'DuendeeTunnel'
New-Item -ItemType Directory -Force -Path $stableDir | Out-Null
$stableSrc = Join-Path $InstallDir 'windows\stable-launch.ps1'
$launchPs1 = Join-Path $stableDir 'launch.ps1'
if (Test-Path -LiteralPath $stableSrc) {
  Copy-Item -LiteralPath $stableSrc -Destination $launchPs1 -Force
}
$stableCmd = Join-Path $stableDir 'launch.cmd'
@(
  '@echo off',
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*'
) -join "`r`n" | Set-Content -LiteralPath $stableCmd -Encoding ASCII
Set-Content -LiteralPath (Join-Path $stableDir 'root.txt') -Value $InstallDir -Encoding ASCII

if (-not $NoDesktopShortcut) {
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'Duendee Tunnel Tool.lnk'
    $w = New-Object -ComObject WScript.Shell
    $sc = $w.CreateShortcut($lnkPath)
    if (Test-Path -LiteralPath $launchPs1) {
      $sc.TargetPath = $stableCmd
      $sc.WorkingDirectory = $stableDir
    } else {
      $sc.TargetPath = Join-Path $InstallDir 'windows\Duendee Tunnel Tool.bat'
      $sc.WorkingDirectory = $InstallDir
    }
    $ico = Join-Path $InstallDir 'windows\Duendee Tunnel Logo.ico'
    if (Test-Path $ico) { $sc.IconLocation = $ico }
    $sc.Description = 'Duendee Tunnel Tool'
    $sc.Save()
    Write-Host "Desktop shortcut: $lnkPath"
  } catch {
    Write-Host "Desktop shortcut skipped: $($_.Exception.Message)"
  }
}

# Ensure this session (irm|iex) can resolve the command immediately
$env:Path = "$BinDir;$env:Path"
# Bundled Node / gh may live under LOCALAPPDATA
$nodeExe = Find-InstallNode
if ($nodeExe) {
  $nodeBin = Split-Path -Parent $nodeExe
  if ($env:Path -notlike "*${nodeBin}*") { $env:Path = "$nodeBin;$env:Path" }
}
$ghExePath = Find-InstallGh
if ($ghExePath) {
  $ghBin = Split-Path -Parent $ghExePath
  if ($env:Path -notlike "*${ghBin}*") { $env:Path = "$ghBin;$env:Path" }
}
$cmdCheck = Get-Command duendee-tunnel -ErrorAction SilentlyContinue

Assert-CoreRuntime -WorkDir $InstallDir
Ensure-GitHubLogin
Invoke-InstallDoctor -WorkDir $InstallDir

Write-Host ""
Write-Host "Install OK ($($info.Tag))"
Write-Host "  Location : $InstallDir"
Write-Host "  Shim     : $(if ($shimInfo) { $shimInfo.Shim } else { Join-Path $BinDir 'duendee-tunnel.cmd' })"
Write-Host "  Run      : duendee-tunnel"
Write-Host "  Doctor   : duendee-tunnel doctor"
if (-not $cmdCheck) {
  Write-Host "  PATH     : `$env:Path = '$BinDir;' + `$env:Path"
}
Write-Host "  Config   : $InstallDir\config.json"
Write-Host "  Not      : Docker gerekmez. Yerel tunel Node+cloudflared ile calisir;"
Write-Host "             filo / private repo icin GitHub girisi (gh auth login) gerekir."

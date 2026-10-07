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
  try {
    Push-Location $WorkDir
    try {
      Write-Host "Running npm install (WhatsApp helper)..."
      & cmd.exe /c "npm.cmd install --omit=dev"
      if ($LASTEXITCODE -ne 0) {
        & cmd.exe /c "npm.cmd install"
      }
      if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: npm install failed (exit $LASTEXITCODE). WhatsApp send may need: npm install in $WorkDir"
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
  $psShim = "#Requires -Version 5.1`r`n" +
    '$Root = Split-Path -Parent $PSScriptRoot' + "`r`n" +
    'Set-Location -LiteralPath $Root' + "`r`n" +
    '& (Join-Path $Root ''windows\duendee-tunnel-tool.ps1'') @args' + "`r`n"
  Set-Content -Path $shimPs1 -Value $psShim -Encoding UTF8

  # Also drop a shim into WindowsApps (often already on User PATH) as a belt-and-suspenders fallback
  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  if (Test-Path $windowsApps) {
    $waShim = Join-Path $windowsApps 'duendee-tunnel.cmd'
    $waBody = @(
      '@echo off',
      'setlocal',
      ('set "TOOL_ROOT={0}"' -f $Root),
      'cd /d "%TOOL_ROOT%"',
      'call "%TOOL_ROOT%\windows\Duendee Tunnel Tool.bat" %*'
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

Write-Host "Installing Duendee Tunnel Tool -> $InstallDir"

$info = Get-ReleaseAssetUrl -Repository $Repo -ReleaseTag $Tag -Name $AssetName
$tmp = Join-Path $env:TEMP ("duendee-tunnel-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp $AssetName
$shimInfo = $null

try {
  Write-Host "Downloading $($info.Tag): $($info.Url)"
  Invoke-WebRequest -Uri $info.Url -OutFile $zip -UseBasicParsing

  if (Test-Path $InstallDir) {
    # Keep user config/session if present
    $keep = @{}
    foreach ($name in @('config.json', '.whatsapp-session', '.tunnelstate')) {
      $p = Join-Path $InstallDir $name
      if (Test-Path $p) {
        $bak = Join-Path $tmp ("keep-" + $name.Replace('.', '_'))
        Copy-Item $p $bak -Recurse -Force
        $keep[$name] = $bak
      }
    }
    Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object {
      $_.Name -notin @('config.json', '.whatsapp-session', '.tunnelstate', 'bin', 'node_modules')
    } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $keep = @{}
  }

  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $extracted = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'Duendee-Tunnel-Tool-Windows-portable*' } | Select-Object -First 1
  if (-not $extracted) { throw 'Zip layout unexpected (missing portable folder).' }

  Copy-Item -Path (Join-Path $extracted.FullName '*') -Destination $InstallDir -Recurse -Force

  foreach ($k in $keep.Keys) {
    $dest = Join-Path $InstallDir $k
    if (-not (Test-Path $dest)) {
      Copy-Item $keep[$k] $dest -Recurse -Force
    }
  }

  $cfgEx = Join-Path $InstallDir 'config.example.json'
  $cfg = Join-Path $InstallDir 'config.json'
  if (-not (Test-Path $cfgEx)) { throw 'Portable zip missing config.example.json' }
  if (-not (Test-Path $cfg)) {
    Copy-Item $cfgEx $cfg -Force
    Write-Host "Created config.json from example - first run will ask for projectPath if needed."
  }

  if (-not $SkipNpm) {
    if ((Get-Command npm.cmd -ErrorAction SilentlyContinue) -or (Get-Command npm -ErrorAction SilentlyContinue)) {
      Invoke-NpmInstallSafe -WorkDir $InstallDir
    } else {
      Write-Host "npm not found - install Node.js, then run: npm install  (in $InstallDir)"
    }
  }
} finally {
  # Shim + PATH must happen even if npm warnings aborted the install body
  try {
    $shimInfo = Install-ShimAndUserPath -Root $InstallDir -Bin $BinDir
  } catch {
    Write-Host "WARNING: shim/PATH setup failed: $($_.Exception.Message)"
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoDesktopShortcut) {
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'Duendee Tunnel Tool.lnk'
    $bat = Join-Path $InstallDir 'windows\Duendee Tunnel Tool.bat'
    $w = New-Object -ComObject WScript.Shell
    $sc = $w.CreateShortcut($lnkPath)
    $sc.TargetPath = $bat
    $sc.WorkingDirectory = $InstallDir
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
$cmdCheck = Get-Command duendee-tunnel -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Install OK ($($info.Tag))"
Write-Host "  Location : $InstallDir"
Write-Host "  Shim     : $(if ($shimInfo) { $shimInfo.Shim } else { Join-Path $BinDir 'duendee-tunnel.cmd' })"
Write-Host "  Run      : duendee-tunnel"
if ($cmdCheck) {
  Write-Host "  Verified : $($cmdCheck.Source)  (same terminal OK)"
} else {
  Write-Host "  Note     : run: `$env:Path = '$BinDir;' + `$env:Path; duendee-tunnel"
}
Write-Host ""
Write-Host "Same-session one-liner:"
Write-Host "  irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex; duendee-tunnel"
Write-Host "  Edit     : $InstallDir\config.json"
Write-Host "  WhatsApp : first send shows QR (WhatsApp > Linked Devices); session saved in .whatsapp-session"

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

Write-Host "Installing Duendee Tunnel Tool -> $InstallDir"

$info = Get-ReleaseAssetUrl -Repository $Repo -ReleaseTag $Tag -Name $AssetName
$tmp = Join-Path $env:TEMP ("duendee-tunnel-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp $AssetName

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

  if (-not (Test-Path (Join-Path $InstallDir 'config.json'))) {
    Copy-Item (Join-Path $InstallDir 'config.example.json') (Join-Path $InstallDir 'config.json') -Force
    Write-Host "Created config.json from example — edit projectPath before starting."
  }

  if (-not $SkipNpm) {
    Push-Location $InstallDir
    try {
      if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "Running npm install (WhatsApp helper)..."
        & npm install --omit=dev 2>$null
        if ($LASTEXITCODE -ne 0) { & npm install }
      } else {
        Write-Host "npm not found — install Node.js, then run: npm install  (in $InstallDir)"
      }
    } finally { Pop-Location }
  }

  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  $bat = Join-Path $InstallDir 'windows\Duendee Tunnel Tool.bat'
  $shimCmd = Join-Path $BinDir 'duendee-tunnel.cmd'
  $shimPs1 = Join-Path $BinDir 'duendee-tunnel.ps1'
  @"
@echo off
setlocal
set "TOOL_ROOT=%~dp0.."
cd /d "%TOOL_ROOT%"
call "%TOOL_ROOT%\windows\Duendee Tunnel Tool.bat" %*
"@ | Set-Content -Path $shimCmd -Encoding ASCII

  @"
#Requires -Version 5.1
`$Root = Split-Path -Parent `$PSScriptRoot
Set-Location -LiteralPath `$Root
& (Join-Path `$Root 'windows\duendee-tunnel-tool.ps1') @args
"@ | Set-Content -Path $shimPs1 -Encoding UTF8

  # Ensure user PATH contains bin
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $userPath) { $userPath = '' }
  $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
  if ($parts -notcontains $BinDir) {
    $newPath = if ($userPath.TrimEnd(';')) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$env:Path;$BinDir"
    Write-Host "Added to user PATH: $BinDir"
  }

  if (-not $NoDesktopShortcut) {
    try {
      $desktop = [Environment]::GetFolderPath('Desktop')
      $lnkPath = Join-Path $desktop 'Duendee Tunnel Tool.lnk'
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

  Write-Host ""
  Write-Host "Install OK ($($info.Tag))"
  Write-Host "  Location : $InstallDir"
  Write-Host "  Run      : duendee-tunnel"
  Write-Host "  (Open a new terminal if PATH was just updated.)"
  Write-Host "  Edit     : $InstallDir\config.json"
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

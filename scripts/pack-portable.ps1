#Requires -Version 5.1
# Build Windows .zip and Linux .tar.gz portable bundles into dist/
[CmdletBinding()]
param(
  [string]$Version = '1.1.3'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dist = Join-Path $Root 'dist'
$Stage = Join-Path $Dist 'stage'

function Copy-Shared([string]$Dest) {
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'scripts') | Out-Null
  Copy-Item (Join-Path $Root 'package.json') $Dest -Force
  Copy-Item (Join-Path $Root 'package-lock.json') $Dest -Force
  Copy-Item (Join-Path $Root 'config.example.json') $Dest -Force
  Copy-Item (Join-Path $Root 'README.md') $Dest -Force
  Copy-Item (Join-Path $Root 'scripts\send-whatsapp.js') (Join-Path $Dest 'scripts') -Force
  Copy-Item (Join-Path $Root 'scripts\whatsapp-config.json') (Join-Path $Dest 'scripts') -Force
  if (Test-Path (Join-Path $Root '.gitattributes')) {
    Copy-Item (Join-Path $Root '.gitattributes') $Dest -Force
  }
}

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

# --- Windows portable ---
$winName = 'Duendee-Tunnel-Tool-Windows-portable'
$winStage = Join-Path $Stage $winName
Copy-Shared $winStage
Copy-Item (Join-Path $Root 'windows') (Join-Path $winStage 'windows') -Recurse -Force
# Drop platform READMEs that assume git clone layout is fine; keep tool README at root
$winZip = Join-Path $Dist "$winName.zip"
if (Test-Path $winZip) { Remove-Item $winZip -Force }
Push-Location $Stage
try {
  Compress-Archive -Path $winName -DestinationPath $winZip -Force
} finally { Pop-Location }
Write-Host "Wrote $winZip"

# --- Linux portable ---
$linName = 'Duendee-Tunnel-Tool-Linux-portable'
$linStage = Join-Path $Stage $linName
Copy-Shared $linStage
Copy-Item (Join-Path $Root 'linux') (Join-Path $linStage 'linux') -Recurse -Force
# Ensure shell scripts use LF (portable archive for Linux)
Get-ChildItem -Path $linStage -Recurse -Include *.sh | ForEach-Object {
  $text = [System.IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n" -replace "`r", "`n"
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($_.FullName, $text, $utf8)
}
$linTar = Join-Path $Dist "$linName.tar.gz"
if (Test-Path $linTar) { Remove-Item $linTar -Force }
Push-Location $Stage
try {
  & tar.exe -czf $linTar $linName
  if ($LASTEXITCODE -ne 0) { throw "tar failed with exit $LASTEXITCODE" }
} finally { Pop-Location }
Write-Host "Wrote $linTar"

# Version stamp for release notes
Set-Content -Path (Join-Path $Dist 'VERSION') -Value $Version -Encoding Ascii
Write-Host "Portable packs ready in dist/ (v$Version)"

#Requires -Version 5.1
# Stable launcher. Lives outside the tool folder so a moved repo still opens.
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Pointer = Join-Path $Here 'root.txt'

function Test-ToolRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $bat = Join-Path $Path 'windows\Duendee Tunnel Tool.bat'
  $mark = Join-Path $Path 'config.example.json'
  return (Test-Path -LiteralPath $bat) -and (Test-Path -LiteralPath $mark)
}

function Add-Unique([System.Collections.Generic.List[string]]$List, [string]$Path) {
  if (-not (Test-ToolRoot $Path)) { return }
  try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return }
  if (-not $List.Contains($full)) { [void]$List.Add($full) }
}

function Search-Tree([string]$Base, [int]$Depth, $List, [bool]$Filter) {
  if ([string]::IsNullOrWhiteSpace($Base) -or -not (Test-Path -LiteralPath $Base)) { return }
  Add-Unique $List $Base
  if ($Depth -le 0) { return }
  $kids = @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue)
  if ($Filter) {
    $kids = @($kids | Where-Object { $_.Name -match 'Duendee|Tunnel|YEK|Cursor' })
  }
  foreach ($kid in $kids) {
    Search-Tree $kid.FullName ($Depth - 1) $List $true
  }
}

$hits = New-Object System.Collections.Generic.List[string]
$saved = ''
if (Test-Path -LiteralPath $Pointer) {
  $saved = "$(Get-Content -LiteralPath $Pointer -Raw -ErrorAction SilentlyContinue)".Trim()
  Add-Unique $hits $saved
}

$root = $null
if ($hits.Count -gt 0) {
  $root = $hits[0]
} else {
  $near = New-Object System.Collections.Generic.List[string]
  if ($saved) {
    $parent = Split-Path -Parent $saved
    Search-Tree $parent 3 $near $false
  }
  foreach ($item in $near) { Add-Unique $hits $item }
  $desktop = [Environment]::GetFolderPath('Desktop')
  $docs = [Environment]::GetFolderPath('MyDocuments')
  $home = $env:USERPROFILE
  foreach ($seed in @(
      (Join-Path $env:LOCALAPPDATA 'DuendeeTunnelTool'),
      (Join-Path $home 'YEK\Cursor'),
      (Join-Path $desktop 'YEK\Cursor'),
      (Join-Path $home 'YEK'),
      (Join-Path $desktop 'YEK'),
      (Join-Path $home 'Cursor'),
      (Join-Path $desktop 'Cursor'),
      $desktop, $docs, $home
    )) {
    Search-Tree $seed 3 $hits $false
  }
  if ($near.Count -gt 0) {
    $root = $near | Sort-Object {
      (Get-Item -LiteralPath (Join-Path $_ 'windows\duendee-tunnel-tool.ps1')).LastWriteTime
    } -Descending | Select-Object -First 1
  } elseif ($hits.Count -gt 0) {
    $root = $hits | Sort-Object {
      (Get-Item -LiteralPath (Join-Path $_ 'windows\duendee-tunnel-tool.ps1')).LastWriteTime
    } -Descending | Select-Object -First 1
  }
}

if (-not $root) {
  Write-Host 'Duendee Tunnel Tool bulunamadi.'
  Write-Host 'Araci yeni klasorunden bir kez acin; kisayol yolu kendisi guncellenir.'
  if (-not $Rest -or $Rest.Count -eq 0) { cmd.exe /c pause }
  exit 1
}

Set-Content -LiteralPath $Pointer -Value $root -Encoding ASCII
$bat = Join-Path $root 'windows\Duendee Tunnel Tool.bat'
& $bat @Rest
exit $LASTEXITCODE

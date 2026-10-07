param(
  [Parameter(Mandatory = $true)][string]$Log,
  [string]$OutLog = "",
  [Parameter(Mandatory = $true)][string]$UrlFile
)

$pattern = 'https://[a-zA-Z0-9\-]+\.(?:trycloudflare\.com|cfargotunnel\.com)'
$ansi = '\x1B\[[0-9;]*[A-Za-z]'

function Read-SharedText([string]$path) {
  $stream = $null
  $reader = $null
  try {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    return $reader.ReadToEnd()
  } catch {
    try {
      return [string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
    } catch {
      return $null
    }
  } finally {
    if ($reader) { $reader.Dispose() }
    elseif ($stream) { $stream.Dispose() }
  }
}

$parts = New-Object System.Collections.Generic.List[object]
foreach ($path in @($OutLog, $Log)) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { continue }
  $text = Read-SharedText $path
  if ([string]::IsNullOrWhiteSpace($text)) { continue }
  try {
    $item = Get-Item -LiteralPath $path
    $stamp = $item.LastWriteTimeUtc
  } catch {
    $stamp = [datetime]::UtcNow
  }
  $text = [regex]::Replace($text, $ansi, '')
  $parts.Add([pscustomobject]@{ Text = $text; Time = $stamp })
}

$blob = (($parts | Sort-Object Time) | ForEach-Object { $_.Text }) -join "`n"
$found = [regex]::Matches($blob, $pattern)
if ($found.Count -eq 0) { exit 1 }

$url = $found[$found.Count - 1].Value.Trim().TrimEnd('/').TrimEnd('|')
$dir = Split-Path -Parent $UrlFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
[IO.File]::WriteAllText($UrlFile, $url)
Write-Output $url
exit 0

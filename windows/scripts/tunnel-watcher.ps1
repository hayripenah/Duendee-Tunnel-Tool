param(
  [Parameter(Mandatory=$true)][int]$ToolPid,
  [Parameter(Mandatory=$true)][string]$Project,
  [Parameter(Mandatory=$true)][string]$ToolRoot
)

$state = Join-Path $ToolRoot ".tunnelstate"
$tunnelPidFile = Join-Path $state "tunnel.pid"
$serverPidFile = Join-Path $state "server.pid"
$qrPng = Join-Path $env:TEMP "duendee-whatsapp-qr.png"
$devPattern = "*cd /d $Project*"

while (Get-Process -Id $ToolPid -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 500
}

# The tool terminal is gone. The link message stays only while the tool is running.
$waJs = Join-Path $ToolRoot 'scripts\send-whatsapp.js'
$sentFile = Join-Path $ToolRoot '.whatsapp-session\sent-links.json'
$creds = Join-Path $ToolRoot '.whatsapp-session\creds.json'
if ((Test-Path -LiteralPath $waJs) -and (Test-Path -LiteralPath $sentFile) -and (Test-Path -LiteralPath $creds)) {
  $raw = Get-Content -LiteralPath $sentFile -Raw -ErrorAction SilentlyContinue
  if (-not [string]::IsNullOrWhiteSpace($raw) -and $raw.Trim() -ne '[]') {
    $node = $null
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $node = $cmd.Source }
    if (-not $node) {
      $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
      foreach ($c in @(
          (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
          $(if ($pf86) { Join-Path $pf86 'nodejs\node.exe' } else { $null }),
          (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
        )) {
        if ($c -and (Test-Path -LiteralPath $c)) { $node = $c; break }
      }
    }
    if ($node) {
      $log = Join-Path $state 'wa-retract.log'
      $env:DT_WA_ACTION = 'retract'
      $env:DT_WA_TIMEOUT_MS = '45000'
      & $node $waJs --retract *>> $log
      Remove-Item Env:DT_WA_ACTION -ErrorAction SilentlyContinue
      Remove-Item Env:DT_WA_TIMEOUT_MS -ErrorAction SilentlyContinue
    }
  }
}

taskkill /IM cloudflared.exe /F 2>$null | Out-Null

foreach ($f in @($tunnelPidFile, $serverPidFile)) {
  if (Test-Path $f) {
    $id = (Get-Content $f | Select-Object -First 1).Trim()
    if ($id -match '^\d+$') {
      taskkill /PID $id /F /T 2>$null | Out-Null
    }
  }
}

$me = $PID
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like $devPattern } |
  ForEach-Object { taskkill /PID $_.ProcessId /F /T 2>$null | Out-Null }

Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowTitle -like '*duendee-whatsapp-qr*' } |
  ForEach-Object { $_.CloseMainWindow() | Out-Null }

Start-Sleep -Milliseconds 300
taskkill /IM PhotosApp.exe /F 2>$null | Out-Null
Remove-Item $qrPng -Force -ErrorAction SilentlyContinue

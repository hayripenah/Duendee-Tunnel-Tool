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
  Start-Sleep -Seconds 1
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

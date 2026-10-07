# Resolve the interactive tool host PID (PowerShell UI or legacy cmd launcher).
$m = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.CommandLine -like '*duendee-tunnel-tool.ps1*' -or
    $_.CommandLine -like '*Duendee Tunnel Tool.bat*'
  } |
  Sort-Object ProcessId |
  Select-Object -First 1
if ($m) { Write-Output $m.ProcessId }

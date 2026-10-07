$m = Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object { $_.CommandLine -like '*Duendee Tunnel Tool.bat*' } | Select-Object -First 1
if ($m) { Write-Output $m.ProcessId }
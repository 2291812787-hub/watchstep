$ErrorActionPreference = 'SilentlyContinue'
$out = 'C:\Users\Public\pre.txt'
'=== iwatch dir ===' | Out-File -FilePath $out -Encoding UTF8
Get-ChildItem 'C:\Users\Public\iwatch' | Select-Object Name,Length | Format-Table -AutoSize | Out-String -Width 200 | Out-File -Append -FilePath $out -Encoding UTF8

'=== iloader procs ===' | Out-File -Append -FilePath $out -Encoding UTF8
Get-Process | Where-Object { $_.ProcessName -like '*iloader*' } | Select-Object Id,ProcessName,StartTime | Format-Table -AutoSize | Out-String -Width 200 | Out-File -Append -FilePath $out -Encoding UTF8

'=== iPhone USB ===' | Out-File -Append -FilePath $out -Encoding UTF8
$p = Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_05AC*' }
if ($p) { $p | Select-Object FriendlyName,Status,InstanceId | Format-Table -AutoSize | Out-String -Width 250 | Out-File -Append -FilePath $out -Encoding UTF8 }
else { 'NO APPLE USB DEVICE' | Out-File -Append -FilePath $out -Encoding UTF8 }

'=== anisette creds ===' | Out-File -Append -FilePath $out -Encoding UTF8
$k = cmdkey /list
$k | Select-String 'anisette|iloader|Target' | Out-String -Width 250 | Out-File -Append -FilePath $out -Encoding UTF8

'=== AMDS ===' | Out-File -Append -FilePath $out -Encoding UTF8
(Get-Service 'Apple Mobile Device Service').Status | Out-File -Append -FilePath $out -Encoding UTF8
'DONE' | Out-File -Append -FilePath $out -Encoding UTF8

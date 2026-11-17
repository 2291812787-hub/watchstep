# step4_pre.ps1 -- pre-flight: device + login service + cred cache. ASCII only.
$out = 'C:\Users\Public\step4_pre.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'

A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$svc = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
A ('  AMDS: ' + $(if ($svc) { $svc.Status + '/' + $svc.StartType } else { 'MISSING' }))

$u = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_05AC' }
if ($u) { foreach ($x in $u) { A ('  USB: ' + $x.Status + ' | ' + $x.Class + ' | ' + $x.FriendlyName) } } else { A '  USB: NONE' }

A '  --- check-login-service ---'
(& $exe --check-login-service 2>&1) | ForEach-Object { A ('  LS: ' + $_) }

A '  --- cached anisette creds ---'
$ck = (& cmdkey /list 2>&1) | Select-String -Pattern 'anisette'
if ($ck) { foreach ($c in $ck) { A ('  CK: ' + ($c.Line -replace '\s+', ' ')) } } else { A '  CK: none' }
A 'DONE'

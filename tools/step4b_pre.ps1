# step4b_pre.ps1 -- pre-flight v2 (string concat fixed). ASCII only.
$out = 'C:\Users\Public\step4b_pre.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'

A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$svc = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
if ($svc) { A ('  AMDS: ' + [string]$svc.Status + ' / ' + [string]$svc.StartType) } else { A '  AMDS: MISSING' }

$u = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_05AC' }
if ($u) { foreach ($x in $u) { A ('  USB: ' + [string]$x.Status + ' | ' + [string]$x.Class + ' | ' + [string]$x.FriendlyName) } } else { A '  USB: NONE' }

A '  --- check-login-service ---'
(& $exe --check-login-service 2>&1) | ForEach-Object { A ('  LS: ' + [string]$_) }

A '  --- cached anisette creds ---'
$ck = (& cmdkey /list 2>&1) | Select-String -Pattern 'anisette'
if ($ck) { foreach ($c in $ck) { A ('  CK: ' + ($c.Line -replace '\s+', ' ')) } } else { A '  CK: none' }
A 'DONE'

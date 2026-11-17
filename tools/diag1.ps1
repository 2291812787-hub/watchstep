# diag1.ps1 -- is there a libimobiledevice package? ASCII only.
$out = 'C:\Users\Public\diag1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$r = (& winget search libimobiledevice --accept-source-agreements 2>&1) -join "`n"
A $r
A '--- done ---'

# when_expire.ps1 -- print when the WatchStep signing expires. ASCII only.
# Double-click when_expire.cmd any time to answer "还有几天会失效？"
$py = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python312\Scripts\pymobiledevice3.exe'
$tmp = 'C:\Users\Public\_prov_tmp.txt'
$log = 'C:\Users\Public\when_expire.log'

if (-not (Test-Path $py)) { Write-Host 'pymobiledevice3 not found'; Read-Host 'Enter'; exit 1 }

& $py provision list > $tmp 2>&1

$text = Get-Content $tmp -Raw -Encoding UTF8
Remove-Item $tmp -ErrorAction SilentlyContinue

# split into blocks and keep only the ones for our bundle id
$blocks = $text -split "(?m)^\s*\{\s*$"
$best = $null
foreach ($b in $blocks) {
    if ($b -notmatch 'watchstep') { continue }
    if ($b -match '"ExpirationDate":\s*"?([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})') {
        $d = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', $null)
        if (-not $best -or $d -gt $best) { $best = $d }
    }
}

$now = Get-Date
if ($best) {
    $days = [math]::Round(($best - $now).TotalDays, 1)
    $line = 'WatchStep signing expires at ' + $best.ToString('yyyy-MM-dd HH:mm') +
            '  ->  ' + $days + ' days left  (checked ' + $now.ToString('yyyy-MM-dd HH:mm') + ')'
    Write-Host ''
    Write-Host $line -ForegroundColor Green
    if ($days -lt 2) {
        Write-Host 'LESS THAN 2 DAYS -- reinstall now: run reinstall_watch.cmd' -ForegroundColor Red
    }
    $line | Out-File -FilePath $log -Append -Encoding UTF8
} else {
    Write-Host 'No WatchStep provisioning profile found.' -ForegroundColor Yellow
    "no profile found at $now" | Out-File -FilePath $log -Append -Encoding UTF8
}
Write-Host ''
Write-Host 'Press Enter to close.'
Read-Host | Out-Null

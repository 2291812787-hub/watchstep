# step6_clear.ps1 -- wipe stale anisette state, verify server, relaunch window. ASCII only.
$ErrorActionPreference = 'Continue'
$out = 'C:\Users\Public\step6_clear.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }

A ('=== ' + (Get-Date -Format 'HH:mm:ss'))

# --- 1) list current anisette targets
$lines = (& cmdkey /list 2>&1)
$targets = @()
foreach ($l in $lines) {
    if ($l -match 'LegacyGeneric:target=(\S*anisette\S*)') { $targets += $Matches[1] }
}
$targets = $targets | Select-Object -Unique
A ('  found_targets=' + $targets.Count)
foreach ($t in $targets) { A ('  target: ' + $t) }

# --- 2) delete them
foreach ($t in $targets) {
    $r = (& cmdkey /delete:$t 2>&1) -join ' '
    A ('  deleted: ' + $t + ' -> ' + $r)
}

# --- 3) confirm gone
$after = @()
foreach ($l in (& cmdkey /list 2>&1)) {
    if ($l -match 'LegacyGeneric:target=(\S*anisette\S*)') { $after += $Matches[1] }
}
$after = $after | Select-Object -Unique
A ('  remaining_targets=' + $after.Count)
foreach ($t in $after) { A ('  still: ' + $t) }

# --- 4) anisette server reachability
try {
    $resp = Invoke-WebRequest -Uri 'https://mac-ani.jkcoxson.com' -TimeoutSec 20 -UseBasicParsing
    A ('  anisette_root=' + $resp.StatusCode)
} catch {
    A ('  anisette_root=FAIL ' + $_.Exception.Message)
}

# --- 5) relaunch
$dir = 'C:\Users\Public\iwatch'
$ipa = 'C:\Users\Public\WatchStep5.ipa'
Get-Process -Name 'iloader-cli' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$args = '/k chcp 65001 >nul & cd /d "' + $dir + '" & iloader-cli.exe "' + $ipa + '" & echo. & echo ==== WINDOW DONE ==== & pause'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList $args -PassThru
A ('  cmd_pid=' + $p.Id)
A '  RESULT=LAUNCHED_FRESH'
A 'DONE'

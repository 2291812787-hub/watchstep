# reinstall_watch.ps1 -- one-click reinstall of the WatchStep watch app. ASCII only.
# Usage:  double-click reinstall_watch.cmd     (or: reinstall_watch.cmd <path-to-ipa>)
# What it does, in order:
#   1. pick the newest *.ipa under C:\Users\Public (or the one given as arg 1)
#   2. kill any leftover iloader process
#   3. delete stale anisette credentials  <-- this is the real cause of -22406
#   4. check the anisette server answers
#   5. open a REAL console window running iloader and leave it for the human
#      (never redirect iloader output; never try to run it detached)
$ErrorActionPreference = 'Continue'
$pub = 'C:\Users\Public'
$exe = Join-Path $pub 'iwatch\iloader-cli.exe'
$log = Join-Path $pub 'reinstall_watch.log'
function A($m) {
    $s = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + [string]$m
    $s | Out-File -FilePath $log -Append -Encoding UTF8
    Write-Host $s
}

A '================ reinstall start ================'

# --- 1) locate ipa
$ipa = $args[0]
if (-not $ipa) {
    $ipa = Get-ChildItem (Join-Path $pub '*.ipa') -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ipa -or -not (Test-Path $ipa)) {
    A 'ERROR: no .ipa found under C:\Users\Public'
    Write-Host ''
    Write-Host 'Put the new .ipa into C:\Users\Public and run this again.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
$item = Get-Item $ipa
A ('ipa=' + $ipa)
A ('size=' + $item.Length + '  mtime=' + $item.LastWriteTime)

# --- 1b) sanity: the exe must exist and be the patched build
if (-not (Test-Path $exe)) {
    A 'ERROR: iloader-cli.exe missing'
    Read-Host 'Press Enter to close'; exit 1
}
$md5 = (Get-FileHash $exe -Algorithm MD5).Hash.ToLower()
A ('iloader_md5=' + $md5 + '  (patched build = 79c512da91a51773f8352f7484f4396b)')

# --- 2) kill leftovers
Get-Process -Name 'iloader-cli','iloader' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# --- 3) wipe stale anisette credentials
$targets = @()
foreach ($l in (& cmdkey /list 2>&1)) {
    if ($l -match 'LegacyGeneric:target=(\S*anisette\S*)') { $targets += $Matches[1] }
}
$targets = $targets | Select-Object -Unique
A ('found_anisette_targets=' + $targets.Count)
foreach ($t in $targets) {
    A ('  target: ' + $t)
    $r = (& cmdkey /delete:$t 2>&1) -join ' '
    A ('  deleted -> ' + $r)
}
$after = @()
foreach ($l in (& cmdkey /list 2>&1)) {
    if ($l -match 'LegacyGeneric:target=(\S*anisette\S*)') { $after += $Matches[1] }
}
A ('remaining_targets=' + ($after | Select-Object -Unique).Count)

# --- 4) anisette server reachable?
try {
    $resp = Invoke-WebRequest -Uri 'https://mac-ani.jkcoxson.com' -TimeoutSec 20 -UseBasicParsing
    A ('anisette_root=' + $resp.StatusCode)
} catch {
    A ('anisette_root=FAIL ' + $_.Exception.Message)
    Write-Host ''
    Write-Host 'WARNING: anisette server not reachable. Login will probably fail.' -ForegroundColor Yellow
}

# --- 5) open the real console window and hand it to the human
$title = 'WATCHSTEP-REINSTALL'
$a = '/k title ' + $title + ' & chcp 65001 >nul & cd /d "' + (Join-Path $pub 'iwatch') + '" & ' +
     'iloader-cli.exe "' + $ipa + '" & echo. & echo ==== iloader finished, exit code %ERRORLEVEL% ==== & pause'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList $a -PassThru
Start-Sleep -Seconds 3
A ('cmd_pid=' + $p.Id)
A 'RESULT=LAUNCHED_FRESH'
A 'NEXT: type the Apple ID password in the WATCHSTEP-REINSTALL window.'
A 'After it finishes, the 7-day clock restarts.'
A '================================================================'
Write-Host ''
Write-Host 'A window titled WATCHSTEP-REINSTALL is open. Type your Apple ID password there.' -ForegroundColor Green

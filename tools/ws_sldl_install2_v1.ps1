# ws_sldl_install2_v1.ps1 -- try NSIS-style silent install, wait up to 90s, report. ASCII only.
$out = 'C:\Users\Public\ws_sldl_install2_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))

$dst = 'C:\Users\Public\SideloadlySetup64.exe'
if (-not (Test-Path $dst)) { A 'SETUP_MISSING'; A '--- done ---'; exit 2 }

foreach ($sw in @('/S','/silent')) {
    A ('TRY switch ' + $sw)
    try {
        $p = Start-Process -FilePath $dst -ArgumentList $sw -PassThru -ErrorAction Stop
        A ('  started pid=' + $p.Id)
        $done = $false
        for ($i = 0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 2
            if ($p.HasExited) { A ('  exited code=' + $p.ExitCode + ' after ' + ($i*2) + 's'); $done = $true; break }
            $dirs = @('C:\Program Files\Sideloadly','C:\Program Files (x86)\Sideloadly',(Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly'))
            foreach ($d in $dirs) { if (Test-Path (Join-Path $d 'Sideloadly.exe')) { A ('  APPEARED ' + $d); $done = $true } }
            if ($done) { break }
        }
        if (-not $done) { A '  still running or no dir; killing'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    } catch {
        A ('  FAIL ' + $_.Exception.Message)
    }
    $dirs = @('C:\Program Files\Sideloadly','C:\Program Files (x86)\Sideloadly',(Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly'))
    $got = $false
    foreach ($d in $dirs) { if (Test-Path (Join-Path $d 'Sideloadly.exe')) { A ('  INSTALLED ' + $d); $got = $true } }
    if ($got) { break }
}
A '--- done ---'

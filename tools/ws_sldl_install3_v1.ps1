# ws_sldl_install3_v1.ps1 -- NSIS silent with explicit /D target. ASCII only.
$out = 'C:\Users\Public\ws_sldl_install3_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))

$setup = 'C:\Users\Public\SideloadlySetup64.exe'
$target = 'C:\Users\Public\Sideloadly'
if (Test-Path $setup) {
    # /D must be last, unquoted, no trailing backslash
    $arg = '/S /D=' + $target
    A ('RUN ' + $arg)
    $p = Start-Process -FilePath $setup -ArgumentList $arg -PassThru
    A ('  pid=' + $p.Id)
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Path (Join-Path $target 'Sideloadly.exe')) { A ('  EXE_APPEARED after ' + ($i*2) + 's'); break }
        if ($p.HasExited -and $i -gt 3) { A ('  parent exited code=' + $p.ExitCode); }
    }
} else { A 'SETUP_MISSING' }

Start-Sleep -Seconds 3
A '--- result ---'
foreach ($d in @('C:\Users\Public\Sideloadly','C:\Program Files\Sideloadly','C:\Program Files (x86)\Sideloadly',(Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly'))) {
    A ('  ' + $d + ' exists=' + (Test-Path $d))
    if (Test-Path $d) {
        Get-ChildItem $d -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { A ('     ' + $_.Name + ' ' + $_.Length) }
    }
}
A '--- done ---'

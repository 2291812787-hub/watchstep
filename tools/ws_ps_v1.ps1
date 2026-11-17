# ws_ps_v1.ps1 -- list relevant processes. ASCII only.
$out = 'C:\Users\Public\ws_ps_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$names = 'SideloadlySetup64','Sideloadly','iloader-cli','powershell','cmd'
foreach ($n in $names) {
    $ps = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($ps) {
        foreach ($p in $ps) {
            A ('  ' + $n + ' pid=' + $p.Id + ' start=' + $p.StartTime.ToString('HH:mm:ss') + ' hwnd=' + $p.MainWindowHandle)
        }
    } else {
        A ('  ' + $n + ' none')
    }
}
A '--- install dirs ---'
foreach ($d in @('C:\Program Files\Sideloadly','C:\Program Files (x86)\Sideloadly',(Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly'))) {
    A ('  ' + $d + ' exists=' + (Test-Path $d))
    if (Test-Path $d) { Get-ChildItem $d -ErrorAction SilentlyContinue | ForEach-Object { A ('     ' + $_.Name + ' ' + $_.Length) } }
}
A '--- done ---'

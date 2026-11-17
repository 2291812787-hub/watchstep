# diag3.ps1 -- find iloader local state (certificate / private key cache) with timestamps. ASCII only.
$out = 'C:\Users\Public\diag3.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$roots = @(
    'C:\Users\Public\iwatch',
    (Join-Path $env:LOCALAPPDATA 'iloader'),
    (Join-Path $env:APPDATA 'iloader'),
    (Join-Path $env:USERPROFILE '.iloader'),
    (Join-Path $env:LOCALAPPDATA 'iDescriptor'),
    (Join-Path $env:APPDATA 'iDescriptor')
)
foreach ($r in $roots) {
    A ('--- ROOT ' + $r + ' exists=' + (Test-Path $r))
    if (Test-Path $r) {
        $fs = Get-ChildItem -Path $r -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 40
        foreach ($f in $fs) {
            A ('    ' + $f.LastWriteTime.ToString('MM-dd HH:mm') + '  ' + $f.Length + '  ' + $f.FullName)
        }
    }
}
A '--- done ---'

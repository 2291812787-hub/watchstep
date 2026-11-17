# ws_ns_v1.ps1 -- inspect NSIS temp extract dirs. ASCII only.
$out = 'C:\Users\Public\ws_ns_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
foreach ($d in @('C:\Users\Administrator\AppData\Local\Temp\nsv1382.tmp','C:\Users\Administrator\AppData\Local\Temp\nsoE675.tmp')) {
    A ('=== ' + $d + ' exists=' + (Test-Path $d))
    if (Test-Path $d) {
        Get-ChildItem $d -Recurse -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object {
            A ('  ' + $_.LastWriteTime.ToString('HH:mm') + ' ' + $_.Length + ' ' + $_.FullName)
        }
    }
}
A '--- done ---'

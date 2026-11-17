# ws_sldl_find_v1.ps1 -- locate Sideloadly.exe under install dir. ASCII only.
$out = 'C:\Users\Public\ws_sldl_find_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$d = 'C:\Users\Public\Sideloadly'
A ('root exists=' + (Test-Path $d))
if (Test-Path $d) {
    $exes = Get-ChildItem $d -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue
    foreach ($e in $exes) { A ('  EXE ' + $e.Length + ' ' + $e.FullName) }
    A ('total_files=' + (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue).Count)
}
A '--- done ---'

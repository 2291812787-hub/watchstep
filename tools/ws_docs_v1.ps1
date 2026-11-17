# ws_docs_v1.ps1 -- dump the tool's own Chinese docs (looking for "app disappears" notes). ASCII only.
$out = 'C:\Users\Public\ws_docs_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$base = 'C:\Users\Public\iwatch'
foreach ($n in @('TROUBLESHOOTING.zh-CN.md','INSTALL.zh-CN.md','PATCH-NOTES.zh-CN.md','README.md')) {
    $p = Join-Path $base $n
    A ('======== ' + $n + ' ========')
    if (Test-Path $p) {
        Get-Content $p -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { A $_ }
    } else { A '  MISSING' }
    A ''
}
A '--- done ---'

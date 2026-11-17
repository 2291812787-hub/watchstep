# ws_certstore_v1.ps1 -- list Apple signing certs in the user cert store. ASCII only.
$out = 'C:\Users\Public\ws_certstore_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
A '--- CurrentUser\My ---'
Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | ForEach-Object {
    A ('  ' + $_.NotBefore.ToString('yyyy-MM-dd HH:mm') + ' -> ' + $_.NotAfter.ToString('yyyy-MM-dd HH:mm') + '  hasPrivKey=' + $_.HasPrivateKey + '  ' + $_.Thumbprint)
    A ('      ' + $_.Subject)
}
A '--- LocalMachine\My (Apple only) ---'
Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match 'Apple' } | ForEach-Object {
        A ('  ' + $_.NotAfter.ToString('yyyy-MM-dd HH:mm') + '  ' + $_.Thumbprint)
        A ('      ' + $_.Subject)
    }
A '--- done ---'

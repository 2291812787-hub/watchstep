# ws_sldl_dl_v1.ps1 -- download Sideloadly installer only. ASCII only.
$out = 'C:\Users\Public\ws_sldl_dl_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# try a few known installer URLs
$urls = @(
    'https://sideloadly.io/SideloadlySetup64.exe',
    'https://sideloadly.io/SideloadlySetup.exe',
    'https://files.sideloadly.io/SideloadlySetup64.exe'
)
foreach ($u in $urls) {
    A ('TRY ' + $u)
    try {
        $r = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 25 -UseBasicParsing -MaximumRedirection 5
        A ('  HEAD ' + $r.StatusCode + ' len=' + $r.Headers['Content-Length'] + ' type=' + $r.Headers['Content-Type'])
    } catch {
        A ('  HEAD_FAIL ' + $_.Exception.Message)
    }
}

$dst = 'C:\Users\Public\SideloadlySetup64.exe'
if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
foreach ($u in $urls) {
    try {
        Invoke-WebRequest -Uri $u -OutFile $dst -TimeoutSec 180 -UseBasicParsing -MaximumRedirection 5
        if ((Test-Path $dst) -and (Get-Item $dst).Length -gt 1000000) {
            A ('DL_OK ' + $u + ' bytes=' + (Get-Item $dst).Length)
            break
        } else {
            A ('DL_TOO_SMALL ' + $u)
        }
    } catch {
        A ('DL_FAIL ' + $u + ' ' + $_.Exception.Message)
    }
}
if (Test-Path $dst) { A ('FINAL bytes=' + (Get-Item $dst).Length) } else { A 'FINAL none' }
A '--- done ---'

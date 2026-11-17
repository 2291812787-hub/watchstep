# ws_sldl_cli_v1.ps1 -- does sideloadly support CLI flags? ASCII only.
$out = 'C:\Users\Public\ws_sldl_cli_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$exe = 'C:\Users\Public\Sideloadly\sideloadly.exe'
A ('exe exists=' + (Test-Path $exe))
# extract readable strings mentioning cli flags
try {
    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $cur = New-Object System.Text.StringBuilder
    $seen = @{}
    $count = 0
    foreach ($b in $bytes) {
        if ($b -ge 32 -and $b -lt 127) { [void]$cur.Append([char]$b) }
        else {
            if ($cur.Length -ge 5) {
                $s = $cur.ToString()
                if ($s -match '^--' -or $s -match '^\-[a-zA-Z]$' -or $s -match 'usage|Usage|USAGE') {
                    if (-not $seen.ContainsKey($s)) { $seen[$s] = 1; A ('  ' + $s); $count++ }
                }
            }
            [void]$cur.Clear()
            if ($count -gt 120) { break }
        }
    }
} catch { A ('  STRING_SCAN_FAIL ' + $_.Exception.Message) }
A '--- done ---'

# diag2.ps1 -- dump command-line flags embedded in iloader-cli.exe. ASCII only.
$out = 'C:\Users\Public\diag2.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$bytes = [System.IO.File]::ReadAllBytes($exe)
$sb = New-Object System.Text.StringBuilder
$cur = New-Object System.Text.StringBuilder
$seen = @{}
foreach ($b in $bytes) {
    if ($b -ge 32 -and $b -lt 127) {
        [void]$cur.Append([char]$b)
    } else {
        if ($cur.Length -ge 6) {
            $s = $cur.ToString()
            if ($s -match '^--' -or $s -match 'revoke' -or $s -match 'certificate' -or $s -match 'profile' -or $s -match 'reset') {
                if (-not $seen.ContainsKey($s)) { $seen[$s] = 1; A $s }
            }
        }
        [void]$cur.Clear()
    }
}
A '--- done ---'

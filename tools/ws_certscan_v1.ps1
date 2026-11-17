# ws_certscan_v1.ps1 -- locate iloader/iDescriptor signing cert + private key cache. ASCII only.
$out = 'C:\Users\Public\ws_certscan_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }

A ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# 1) everything under iwatch dir with timestamps
$base = 'C:\Users\Public\iwatch'
A ('--- ' + $base + ' ---')
if (Test-Path $base) {
    Get-ChildItem -Path $base -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 60 | ForEach-Object {
            $t = if ($_.PSIsContainer) { 'DIR ' } else { 'FILE' }
            A ('  ' + $_.LastWriteTime.ToString('MM-dd HH:mm') + '  ' + $t + '  ' + $_.Length + '  ' + $_.FullName)
        }
} else { A '  MISSING' }

# 2) cert-ish files anywhere obvious
$pat = @('*.p12','*.pfx','*.pem','*.key','*.cer','*.crt','*.der','*.mobileprovision','*.provision')
$places = @(
    'C:\Users\Public',
    'C:\Users\Administrator',
    (Join-Path $env:LOCALAPPDATA 'Apple'),
    (Join-Path $env:APPDATA 'Apple'),
    (Join-Path $env:USERPROFILE 'Documents')
)
A '--- cert files ---'
foreach ($p in $places) {
    foreach ($g in $pat) {
        Get-ChildItem -Path $p -Filter $g -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object -First 8 | ForEach-Object {
                A ('  ' + $_.LastWriteTime.ToString('MM-dd HH:mm') + '  ' + $_.Length + '  ' + $_.FullName)
            }
    }
}

# 3) top-level appdata dirs that look like these tools
A '--- appdata dirs ---'
foreach ($p in @($env:LOCALAPPDATA, $env:APPDATA)) {
    Get-ChildItem -Path $p -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'load|idescrip|nerves|side|apple|hermes' } |
        ForEach-Object { A ('  ' + $p + ' :: ' + $_.Name + '  ' + $_.LastWriteTime.ToString('MM-dd HH:mm')) }
}
A '--- done ---'

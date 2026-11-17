# ws_sldl_install_v1.ps1 -- install Sideloadly silently, then report where it landed. ASCII only.
$out = 'C:\Users\Public\ws_sldl_install_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$dst = 'C:\Users\Public\SideloadlySetup64.exe'
if (-not (Test-Path $dst)) { A 'SETUP_MISSING'; A '--- done ---'; exit 2 }
A ('setup bytes=' + (Get-Item $dst).Length)

# Inno Setup silent switches
$p = Start-Process -FilePath $dst -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -PassThru -Wait
A ('exit=' + $p.ExitCode)

Start-Sleep -Seconds 3
$cands = @(
    'C:\Program Files\Sideloadly\Sideloadly.exe',
    'C:\Program Files (x86)\Sideloadly\Sideloadly.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly\Sideloadly.exe'),
    (Join-Path $env:LOCALAPPDATA 'Sideloadly\Sideloadly.exe')
)
$found = $null
foreach ($c in $cands) { if (Test-Path $c) { A ('FOUND ' + $c); $found = $c } }
if (-not $found) {
    A 'SEARCHING...'
    $hit = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'Sideloadly.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 3
    foreach ($h in $hit) { A ('HIT ' + $h.FullName + ' bytes=' + $h.Length); $found = $h.FullName }
}
if (-not $found) { A 'NOT_INSTALLED' }
A '--- done ---'

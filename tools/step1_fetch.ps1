# step1_fetch.ps1 -- ONE round-trip only: download newest IPA from CI, verify, check, list devices.
# ASCII only (PowerShell 5.1 reads ANSI when no BOM).
$ErrorActionPreference = 'Continue'
$dst = 'C:\Users\Public\WatchStep5.ipa'
$url = 'https://gh-proxy.com/https://raw.githubusercontent.com/2291812787-hub/watchstep/ci-build/WatchStep.ipa'
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'

Write-Output '=== STEP1 download ==='
if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
$ok = $false
try {
    Invoke-WebRequest -Uri $url -OutFile $dst -TimeoutSec 240 -UseBasicParsing
    $ok = $true
} catch {
    Write-Output ('DL_FAIL ' + $_.Exception.Message)
}
if ($ok -and (Test-Path $dst)) {
    $f = Get-Item $dst
    $h = (Get-FileHash $dst -Algorithm SHA256).Hash
    Write-Output ('DL_OK bytes=' + $f.Length + ' sha=' + $h)
} else {
    Write-Output 'DL_ABORT'
}

Write-Output '=== STEP2 check-ipa ==='
if ((Test-Path $dst) -and (Test-Path $exe)) {
    & $exe --check-ipa $dst 2>&1 | ForEach-Object { Write-Output $_ }
} else {
    Write-Output 'SKIP check-ipa'
}

Write-Output '=== STEP3 bundle sanity ==='
if (Test-Path $dst) {
    $tmp = 'C:\Users\Public\_ipax5'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($dst, $tmp)
        $wi = Join-Path $tmp 'Payload\WatchStep.app\Watch\WatchStepWatch.app\Info.plist'
        $pi = Join-Path $tmp 'Payload\WatchStep.app\Info.plist'
        Write-Output ('watch_plist_exists=' + (Test-Path $wi) + ' phone_plist_exists=' + (Test-Path $pi))
    } catch {
        Write-Output ('UNZIP_FAIL ' + $_.Exception.Message)
    }
}

Write-Output '=== STEP4 devices ==='
if (Test-Path $exe) {
    & $exe --list-devices 2>&1 | ForEach-Object { Write-Output $_ }
} else {
    Write-Output 'NO_ILOADER'
}
Write-Output 'DONE'

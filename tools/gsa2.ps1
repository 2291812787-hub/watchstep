$out = @()
foreach ($u in @('https://gsa.apple.com/grandslam/GsService2','https://developerservices2.apple.com/services/QH65B2/','https://idmsa.apple.com/IDMSWebAuth/','https://gsa.apple.com/')) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri $u -Method Get -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
    $code = [int]$r.StatusCode
  } catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  }
  $sw.Stop()
  $out += ("{0} -> {1} ({2}ms)" -f $u, $code, $sw.ElapsedMilliseconds)
}
$out += ""
$out += "--- DNS ---"
foreach ($h in @('gsa.apple.com','developerservices2.apple.com','idmsa.apple.com')) {
  try { $a = [Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.IPAddressToString }
    $out += ("{0} = {1}" -f $h, ($a -join ',')) } catch { $out += ("{0} = DNSFAIL" -f $h) }
}
$out | Out-File -FilePath C:\Users\Public\gsa.txt -Encoding UTF8
$out | Write-Output

$p="http://127.0.0.1:10809"
$o=@()
try{$r=Invoke-WebRequest -Uri "https://gsa.apple.com/grandslam/GsService2" -Proxy $p -TimeoutSec 25 -UseBasicParsing; $o+="VIA_PROXY="+$r.StatusCode}catch{$o+="VIA_PROXY_FAIL "+$_.Exception.Message}
try{$r2=Invoke-WebRequest -Uri "https://gsa.apple.com/" -Proxy $p -TimeoutSec 25 -UseBasicParsing; $o+="GSA_ROOT="+$r2.StatusCode}catch{$o+="GSA_ROOT_FAIL "+$_.Exception.Message}
$o | Out-File -FilePath C:\Users\Public\p3.txt -Encoding UTF8

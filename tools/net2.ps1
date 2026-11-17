$o='C:\Users\Public\net2.txt'
Remove-Item $o -EA 0
foreach($u in @('https://ppq.apple.com','https://ocsp.apple.com','https://developerservices2.apple.com','https://gsa.apple.com')){
  $t=Measure-Command { try { $r=Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop; $code=$r.StatusCode } catch { $code=('ERR:' + $_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length))) } }
  ($u + ' -> ' + $code + '  ' + [int]$t.TotalMilliseconds + 'ms') | Out-File $o -Append -Encoding UTF8
}
'PROXY: ' + (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -EA 0).ProxyEnable | Out-File $o -Append -Encoding UTF8
'PROXYSERVER: ' + (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -EA 0).ProxyServer | Out-File $o -Append -Encoding UTF8
'=== END ===' | Out-File $o -Append -Encoding UTF8

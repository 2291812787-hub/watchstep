$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Write-Output "=== SYSTEM PROXY ==="
Get-ItemProperty $k | Select-Object ProxyEnable,ProxyServer,AutoConfigURL | Format-List | Out-String
Write-Output "=== ENV PROXY ==="
Write-Output ("HTTP=" + $env:HTTP_PROXY + " HTTPS=" + $env:HTTPS_PROXY)
Write-Output "=== LISTEN PORTS ==="
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -lt 65000 -and $_.LocalPort -gt 1000} | Select-Object LocalAddress,LocalPort,OwningProcess | Sort-Object LocalPort | Format-Table -AutoSize | Out-String -Width 200
Write-Output "=== PROXY-ISH PROCS ==="
Get-Process | Where-Object {$_.ProcessName -match "clash|v2ray|xray|sing|trojan|shadowsocks|ss-|nekoray|verge|mihomo|warp|proxy|surge|quantumult"} | Select-Object Id,ProcessName | Format-Table -AutoSize | Out-String

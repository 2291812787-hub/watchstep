Write-Output "=== LISTEN 108xx ==="
netstat -ano | Select-String "127.0.0.1:1080|0.0.0.0:1080|127.0.0.1:789|:10809"
Write-Output "=== PROXY PROCS ==="
Get-Process | Where-Object { $_.ProcessName -match "clash|v2ray|xray|sing-box|trojan|ssr|shadow|verge|nekoray|hysteria" } | Select-Object ProcessName,Id | Format-Table -AutoSize | Out-String

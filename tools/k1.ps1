$o='C:\Users\Public\k1.txt'
Remove-Item $o -EA 0
Get-Process sideloadly -EA 0 | Stop-Process -Force -EA 0
Start-Sleep -Seconds 1
$n=(Get-Process sideloadly -EA 0 | Measure-Object).Count
Add-Content $o ('sideloadly_left=' + $n)
Add-Content $o 'DONE'

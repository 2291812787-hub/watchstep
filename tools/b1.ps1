$o='C:\Users\Public\b1.txt'
Remove-Item $o -EA 0
Start-Process 'https://developer.apple.com/account/resources/certificates/list'
Start-Sleep -Seconds 3
Add-Content $o 'OPENED'

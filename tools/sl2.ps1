$o='C:\Users\Public\sl2.txt'
Remove-Item $o -EA 0
$exe='C:\Users\Public\Sideloadly\sideloadly.exe'
$p=Start-Process $exe -ArgumentList 'C:\Users\Public\WatchStep6.ipa' -PassThru
Add-Content $o ('pid=' + $p.Id)
Start-Sleep -Seconds 12
Add-Content $o 'OPENED'

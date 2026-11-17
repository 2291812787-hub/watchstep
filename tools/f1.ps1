$o='C:\Users\Public\f1.txt'
Remove-Item $o -EA 0
$r=Get-ChildItem 'C:\Users\Administrator\AppData\Local\Temp' -Recurse -Include *.ipa,*.app -EA 0 | Sort-Object LastWriteTime -Desc | Select-Object -First 12
$r | ForEach-Object { [string]($_.FullName+' | '+$_.LastWriteTime) | Out-File $o -Append -Encoding UTF8 }
Add-Content $o 'END'

$o='C:\Users\Public\b2.txt'
Remove-Item $o -EA 0
Get-Process | Where-Object { $_.MainWindowTitle -ne '' } | ForEach-Object {
  [string]($_.ProcessName + ' :: ' + $_.MainWindowTitle) | Out-File $o -Append -Encoding UTF8
}
Add-Content $o 'END'

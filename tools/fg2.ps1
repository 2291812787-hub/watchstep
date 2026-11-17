$o='C:\Users\Public\fg2.txt'
Remove-Item $o -EA 0
$p=Get-Process sideloadly -EA 0 | Select-Object -First 1
if ($p) {
  Add-Content $o ('found pid=' + $p.Id + ' title=' + $p.MainWindowTitle)
} else {
  Add-Content $o 'not running'
}
Add-Content $o 'END'

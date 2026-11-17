$o='C:\Users\Public\f3.txt'
Remove-Item $o -EA 0
$p=$env:APPDATA+'\Sideloadly'
Add-Content $o ('APPDATA_SL=' + $p + ' exists=' + (Test-Path $p))
if (Test-Path $p) {
  Get-ChildItem $p -Recurse -EA 0 | ForEach-Object { [string]($_.FullName + ' | ' + $_.Length) | Out-File $o -Append -Encoding UTF8 }
}
Add-Content $o 'END'

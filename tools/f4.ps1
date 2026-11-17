$o='C:\Users\Public\f4.txt'
Remove-Item $o -EA 0
$dirs=@('C:\Users\Public\iwatch','C:\Users\Administrator\AppData\Local\iwatch','C:\Users\Administrator\AppData\Roaming\iwatch','C:\Users\Administrator\.iwatch')
foreach($d in $dirs){
  Add-Content $o ('=== ' + $d + ' exists=' + (Test-Path $d))
  if(Test-Path $d){
    Get-ChildItem $d -Recurse -EA 0 | Select-Object -First 40 | ForEach-Object { [string]($_.FullName + ' | ' + $_.Length) | Out-File $o -Append -Encoding UTF8 }
  }
}
Add-Content $o 'END'

$o='C:\Users\Public\ik1.txt'
Remove-Item $o -EA 0
$dirs=@('C:\Users\Public\iwatch','C:\Users\Administrator\AppData\Roaming\iloader','C:\Users\Administrator\AppData\Local\iloader','C:\Users\Administrator\.iloader')
foreach($d in $dirs){
  Add-Content $o ('== ' + $d + ' ' + (Test-Path $d))
  if(Test-Path $d){
    Get-ChildItem $d -Recurse -File -EA 0 | ForEach-Object { [string]($_.FullName + ' | ' + $_.Length + ' | ' + $_.LastWriteTime) | Out-File $o -Append -Encoding UTF8 }
  }
}
Add-Content $o 'END'

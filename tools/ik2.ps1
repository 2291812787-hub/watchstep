$o='C:\Users\Public\ik2.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

W '=== CMDKEY ==='
cmdkey /list 2>&1 | Out-File $o -Append -Encoding UTF8

W ''
W '=== HIDDEN FILES iwatch ==='
Get-ChildItem 'C:\Users\Public\iwatch' -Force -EA 0 | ForEach-Object { W ('H ' + $_.Name + ' | ' + $_.Length + ' | ' + $_.Attributes) }

W ''
W '=== ANY dir named *iloader* / *watchgroup* under Users+ProgramData ==='
foreach($root in @('C:\Users\Administrator\AppData\Roaming','C:\Users\Administrator\AppData\Local','C:\ProgramData','C:\Users\Public')){
  Get-ChildItem $root -Directory -Force -Recurse -Depth 3 -EA 0 | Where-Object { $_.Name -match 'iloader|watchgroup' } | ForEach-Object { W ('D ' + $_.FullName) }
}

W ''
W '=== REGISTRY ==='
foreach($k in @('HKCU:\Software\iloader','HKCU:\Software\AndreySemjonov','HKCU:\Software\watchgroup')){
  W ($k + ' exists=' + (Test-Path $k))
  if(Test-Path $k){ Get-ChildItem $k -Recurse -EA 0 | ForEach-Object { W ('K ' + $_.Name) } }
}
W '=== END ==='

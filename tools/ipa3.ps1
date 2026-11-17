$o='C:\Users\Public\ipa3.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

W '=== IPA FILES ==='
foreach($d in @('C:\Users\Public','C:\Users\Administrator\AppData\Local\Temp','C:\Users\Public\iwatch')){
  Get-ChildItem $d -Filter *.ipa -Force -EA 0 | ForEach-Object { W ($_.FullName + ' | ' + $_.Length + ' | ' + $_.LastWriteTime) }
}

W ''
W '=== EXTRACTED DIRS: has profile? ==='
foreach($d in (Get-ChildItem 'C:\Users\Administrator\AppData\Local\Temp' -Directory -Filter '*ipa_extracted' -Force -EA 0)){
  W ('-- ' + $d.Name + '  mtime=' + $d.LastWriteTime)
  Get-ChildItem $d.FullName -Recurse -Force -EA 0 | ForEach-Object {
    W ('   ' + $_.FullName.Replace($d.FullName,'') + ' | ' + $_.Length)
  }
}
W '=== END ==='

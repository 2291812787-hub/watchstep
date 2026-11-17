$o='C:\Users\Public\sl_log.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

W '=== Sideloadly 目录树 ==='
foreach($base in @('C:\Users\Administrator\AppData\Local\Sideloadly','C:\Users\Administrator\AppData\Roaming\Sideloadly','C:\Users\Public\Sideloadly')){
  if(Test-Path $base){
    W ('-- ' + $base)
    Get-ChildItem $base -Force -EA 0 | ForEach-Object { W ('   ' + $_.Name + ' | ' + $_.Length + ' | ' + $_.LastWriteTime) }
  } else { W ('-- ' + $base + '  MISSING') }
}

W ''
W '=== 找 log/txt/json 文件（近 2 天） ==='
$since=(Get-Date).AddDays(-2)
foreach($base in @('C:\Users\Administrator\AppData\Local\Sideloadly','C:\Users\Administrator\AppData\Roaming\Sideloadly')){
  if(Test-Path $base){
    Get-ChildItem $base -Recurse -Force -Include *.log,*.txt,*.json,*.plist -EA 0 |
      Where-Object { $_.LastWriteTime -gt $since } |
      ForEach-Object { W ('   ' + $_.FullName + ' | ' + $_.Length + ' | ' + $_.LastWriteTime) }
  }
}
W '=== END ==='

$o='C:\Users\Public\insp1.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

W '=== TROUBLESHOOTING ==='
if(Test-Path 'C:\Users\Public\iwatch\TROUBLESHOOTING.zh-CN.md'){ Get-Content 'C:\Users\Public\iwatch\TROUBLESHOOTING.zh-CN.md' -Encoding UTF8 | Out-File $o -Append -Encoding UTF8 }

W ''
W '=== ROMAING DIRS ==='
Get-ChildItem 'C:\Users\Administrator\AppData\Roaming' -Force -EA 0 | ForEach-Object { W ('R ' + $_.Name) }
W '=== LOCAL DIRS (match load/ani) ==='
Get-ChildItem 'C:\Users\Administrator\AppData\Local' -Force -EA 0 | Where-Object { $_.Name -match 'load|ani|ios|apple' } | ForEach-Object { W ('L ' + $_.Name) }
W '=== TEMP (match) ==='
Get-ChildItem 'C:\Users\Administrator\AppData\Local\Temp' -Force -EA 0 | Where-Object { $_.Name -match 'load|ani|Watch' } | ForEach-Object { W ('T ' + $_.Name + ' | ' + $_.LastWriteTime) }
W '=== P12/PFX/PEM under Users ==='
Get-ChildItem 'C:\Users' -Recurse -Force -Depth 6 -Include *.p12,*.pfx,*.pem,*.mobileprovision -EA 0 | ForEach-Object { W ('F ' + $_.FullName + ' | ' + $_.Length) }

W ''
W '=== SIDELOADLY STRINGS evoke ==='
$b=[IO.File]::ReadAllBytes('C:\Users\Public\Sideloadly\sideloadly.exe')
$s=[Text.Encoding]::ASCII.GetString($b)
$i=0; $n=0
while($n -lt 15){
  $i=$s.IndexOf('evoke',$i)
  if($i -lt 0){ break }
  W ('CTX: ' + $s.Substring([Math]::Max(0,$i-70),140).Replace([string][char]0,'.'))
  $i=$i+6; $n++
}
W '=== END ==='

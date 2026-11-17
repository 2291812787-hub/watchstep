$o='C:\Users\Public\sl3.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }
W '=== HELP ==='
$p=Start-Process 'C:\Users\Public\Sideloadly\sideloadly.exe' -ArgumentList '--help' -PassThru -RedirectStandardOutput 'C:\Users\Public\slh.txt' -RedirectStandardError 'C:\Users\Public\slhe.txt' -WindowStyle Hidden
Start-Sleep -Seconds 8
if(-not $p.HasExited){ Stop-Process $p.Id -Force -EA 0 }
foreach($f in @('slh.txt','slhe.txt')){ W ('-- ' + $f); if(Test-Path ('C:\Users\Public\'+$f)){ Get-Content ('C:\Users\Public\'+$f) | Out-File $o -Append -Encoding UTF8 } }
W '=== FLAGS in binary ==='
$b=[IO.File]::ReadAllBytes('C:\Users\Public\Sideloadly\sideloadly.exe')
$s=[Text.Encoding]::ASCII.GetString($b)
$i=0;$n=0
while($n -lt 40){
  $i=$s.IndexOf('--',$i)
  if($i -lt 0){break}
  $seg=$s.Substring($i,[Math]::Min(24,$s.Length-$i))
  $ok=$true
  foreach($c in $seg.ToCharArray()){ if([int]$c -lt 32 -or [int]$c -gt 126){ $ok=$false; break } }
  if($ok -and $seg -match '^--[a-zA-Z]{3,20}$'){ W ('F ' + $seg); $n++ }
  $i=$i+2
}
W '=== END ==='

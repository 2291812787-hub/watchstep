$o='C:\Users\Public\sl_grep.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

$log='C:\Users\Public\Sideloadly\sideloadlydaemon.log'
W ('=== daemon.log size=' + (Get-Item $log).Length + ' ===')

$lines = Get-Content $log -Encoding UTF8
W ('total lines=' + $lines.Count)

W ''
W '=== 含 Watch/ watch /WatchStep 的行 ==='
$hit = $lines | Select-String -Pattern 'watch|Watch|watchkit|WatchStep' -SimpleMatch:$false
W ('hits=' + $hit.Count)
foreach($h in $hit){ W ('   ' + $h.Line.Trim()) }

W ''
W '=== 最后 60 行 ==='
$lines[-60..-1] | ForEach-Object { W ('| ' + $_.Trim()) }
W '=== END ==='

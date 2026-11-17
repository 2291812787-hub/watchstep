$o='C:\Users\Public\s2.txt'
Remove-Item $o -EA 0
$b=[System.IO.File]::ReadAllBytes('C:\Users\Public\Sideloadly\sideloadly.exe')
$t=[System.Text.Encoding]::Latin1.GetString($b)
$hits=0
$idx=0
while($hits -lt 12){
  $i=$t.IndexOf('evoke',$idx)
  if($i -lt 0){break}
  $s=[Math]::Max(0,$i-90); $len=[Math]::Min(200,$t.Length-$s)
  Add-Content $o ($t.Substring($s,$len) -replace '[^\x20-\x7E]','.')
  Add-Content $o '-----'
  $idx=$i+6; $hits=$hits+1
}
Add-Content $o ('hits=' + $hits)

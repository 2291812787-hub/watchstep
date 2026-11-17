$o='C:\Users\Public\s3.txt'
Remove-Item $o -EA 0
$f='C:\Users\Public\Sideloadly\sideloadlydaemon.exe'
Add-Content $o ('exists=' + (Test-Path $f))
$s=[System.IO.File]::ReadAllText($f,[System.Text.Encoding]::GetEncoding(28591))
foreach($k in @('Revoke','revoke','Certificate','certificate')){
  $n=0; $i=0
  while(($i=$s.IndexOf($k,$i)) -ge 0 -and $n -lt 6){
    Add-Content $o ($k + ' >> ' + $s.Substring([Math]::Max(0,$i-70),[Math]::Min(150,$s.Length-[Math]::Max(0,$i-70))))
    $i++; $n++
  }
}
Add-Content $o 'END'

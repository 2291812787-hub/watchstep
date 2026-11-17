$o='C:\Users\Public\s1.txt'
Remove-Item $o -EA 0
$p='C:\Users\Public\Sideloadly\sideloadly.exe'
Add-Content $o ('exe=' + (Test-Path $p))
$b=[System.IO.File]::ReadAllBytes($p)
$t=[System.Text.Encoding]::ASCII.GetString($b)
$ms=[regex]::Matches($t,'[ -~]{5,60}')
$seen=@{}
foreach($m in $ms){
  $v=$m.Value
  if($v -match '(?i)revoke|certificat|--'){
    if(-not $seen.ContainsKey($v)){ $seen[$v]=1 }
  }
}
$seen.Keys | Sort-Object | Select-Object -First 60 | ForEach-Object { [string]$_ | Out-File $o -Append -Encoding UTF8 }
Add-Content $o 'END'

$ErrorActionPreference='SilentlyContinue'
Get-Process iloader-cli | Stop-Process -Force
Start-Sleep -Seconds 2
$cks = cmdkey /list | Select-String 'Target: LegacyGeneric'
$targets = @()
foreach($l in $cks){ $s=$l.ToString(); if($s -match 'Target: LegacyGeneric:(.*)$'){ $targets += $Matches[1].Trim() } }
$out = @()
foreach($t in $targets){
  if($t -like '*anisette_state*'){
    cmdkey /delete:$t | Out-Null
    $out += "DEL $t"
  } else { $out += "KEEP $t" }
}
$out += "REMAIN:"
$out += (cmdkey /list | Select-String 'LegacyGeneric')
$out | Set-Content -Path C:\Users\Public\reset9.txt -Encoding UTF8
Write-Output ($out -join ';')

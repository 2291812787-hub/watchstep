$o='C:\Users\Public\prof1.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

$files=@(
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep2.ipa_extracted\Payload\WatchStep.app\embedded.mobileprovision',
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep2.ipa_extracted\Payload\WatchStep.app\Watch\WatchStepWatch.app\embedded.mobileprovision',
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep3.ipa_extracted\Payload\WatchStep.app\embedded.mobileprovision',
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep3.ipa_extracted\Payload\WatchStep.app\Watch\WatchStepWatch.app\embedded.mobileprovision',
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep5.ipa_extracted\Payload\WatchStep.app\embedded.mobileprovision',
 'C:\Users\Administrator\AppData\Local\Temp\WatchStep5.ipa_extracted\Payload\WatchStep.app\Watch\WatchStepWatch.app\embedded.mobileprovision'
)
foreach($f in $files){
  W ('##### ' + $f)
  if(-not (Test-Path $f)){ W 'MISSING'; continue }
  $b=[IO.File]::ReadAllBytes($f)
  $s=[Text.Encoding]::ASCII.GetString($b)
  $i=$s.IndexOf('<?xml'); $j=$s.IndexOf('</plist>')
  if($i -lt 0 -or $j -lt 0){ W 'NO PLIST'; continue }
  $pl=$s.Substring($i,$j-$i+8)
  $out='C:\Users\Public\p_tmp.plist'
  [IO.File]::WriteAllText($out,$pl,[Text.Encoding]::UTF8)
  try { [xml]$x=Get-Content $out -Encoding UTF8 } catch { W 'XMLFAIL'; continue }
  $keys=$x.plist.dict.ChildNodes
  for($k=0;$k -lt $keys.Count;$k++){
    if($keys[$k].Name -ne 'key'){ continue }
    $name=$keys[$k].InnerText
    if($name -match 'Platform|ProvisionedDevices|AppIDName|^Name$|get-task-allow|application-identifier|beta-reports-active|TeamName|ExpirationDate|CreationDate|com.apple.developer.team-identifier'){
      $val=$keys[$k+1]
      $txt=''
      if($val.Name -eq 'array'){ $txt=($val.string -join ',') }
      elseif($val.Name -eq 'true'){ $txt='true' }
      elseif($val.Name -eq 'false'){ $txt='false' }
      else { $txt=$val.InnerText }
      W ('  ' + $name + ' = ' + $txt)
    }
  }
  $uuid=@()
  foreach($m in [Regex]::Matches($s,'[0-9a-fA-F]{40}')){ $uuid += $m.Value }
  W ('  RAW40: ' + (($uuid | Select-Object -Unique) -join ' '))
}
W '=== END ==='

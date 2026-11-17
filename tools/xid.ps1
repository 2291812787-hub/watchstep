$o='C:\Users\Public\xid.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

$base='C:\Users\Administrator\AppData\Local\Temp\WatchStep2.ipa_extracted\Payload\WatchStep.app'
foreach($p in @($base, "$base\Watch\WatchStepWatch.app")){
  W ('##### ' + $p)
  $ip = Join-Path $p 'Info.plist'
  if(Test-Path $ip){
    try{
      $x=[xml](Get-Content $ip -Raw -Encoding UTF8)
      if($x.plist){ $pl=$x.plist.dict } else { $pl=$null }
      if($pl){
        $k=$pl.ChildNodes
        for($i=0;$i -lt $k.Count;$i++){
          if($k[$i].Name -ne 'key'){ continue }
          $n=$k[$i].InnerText
          if($n -match 'CFBundleIdentifier|CFBundleExecutable|WKCompanion|WKWatch|WKApplication'){
            W ('   ' + $n + ' = ' + $k[$i+1].InnerText)
          }
        }
      } else { W '   (binary plist, 稍后另解)' }
    } catch { W ('   XMLFAIL ' + $_.Exception.Message) }
  } else { W '   NO Info.plist' }
  # 二进制 plist 兜底：直接搜可打印字符串
  $b=[IO.File]::ReadAllBytes($ip)
  $s=[Text.Encoding]::ASCII.GetString($b)
  W ('   RAW-has-34AQFYMZ25 : ' + $s.Contains('34AQFYMZ25'))
  foreach($m in [Regex]::Matches($s,'top\.webchangming\.watchstep[A-Za-z0-9\.\-]*')){
    W ('   RAW-ID: ' + $m.Value)
  }
}
W '=== END ==='

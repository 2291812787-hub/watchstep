$o='C:\Users\Public\mp.txt'
Remove-Item $o -EA 0
function W($t){ $t | Out-File $o -Append -Encoding UTF8 }

W '=== 全盘 mobileprovision（今天） ==='
$files = Get-ChildItem 'C:\Users' -Recurse -Force -Include *.mobileprovision -EA 0 | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-2) }
W ('found=' + $files.Count)

foreach($f in $files){
  W ('---- ' + $f.FullName + ' | ' + $f.Length + ' | ' + $f.LastWriteTime)
  $bytes = [IO.File]::ReadAllBytes($f.FullName)
  $s = [Text.Encoding]::ASCII.GetString($bytes)
  $a = $s.IndexOf('<plist')
  $b = $s.LastIndexOf('</plist>')
  if($a -ge 0 -and $b -gt $a){
    $xml = $s.Substring($a, $b-$a+8)
    try{
      [xml]$x = $xml
      $keys = $x.plist.dict.ChildNodes
      for($i=0;$i -lt $keys.Count;$i++){
        if($keys[$i].Name -ne 'key'){ continue }
        $n = $keys[$i].InnerText
        if($n -eq 'Platform' -or $n -eq 'ExpirationDate' -or $n -eq 'CreationDate' -or $n -eq 'Name'){
          W ('     ' + $n + ' = ' + $keys[$i+1].InnerText)
        }
        if($n -eq 'DeveloperCertificates'){
          $arr = $keys[$i+1]
          W ('     DeveloperCertificates n=' + $arr.array.data.Count)
          foreach($dd in $arr.array.data){
            $der = [Convert]::FromBase64String(($dd.InnerText -replace '\s',''))
            $tmp = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllBytes($tmp, $der)
            $p = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($tmp)
            W ('        SERIAL=' + $p.SerialNumber + '  CN=' + $p.GetNameInfo('SimpleName', $true))
            Remove-Item $tmp -Force -EA 0
          }
        }
      }
    } catch { W ('     XMLPARSEFAIL') }
  } else { W '     no plist found' }
}
W '=== END ==='

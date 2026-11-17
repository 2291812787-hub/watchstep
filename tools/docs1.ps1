$o='C:\Users\Public\docs1.txt'
Remove-Item $o -EA 0
foreach($f in @('README.md','PATCH-NOTES.zh-CN.md','INSTALL.zh-CN.md')){
  ('##### ' + $f) | Out-File $o -Append -Encoding UTF8
  if(Test-Path ('C:\Users\Public\iwatch\' + $f)){
    Get-Content ('C:\Users\Public\iwatch\' + $f) -Encoding UTF8 | Out-File $o -Append -Encoding UTF8
  } else { 'MISSING' | Out-File $o -Append -Encoding UTF8 }
}
'=== END ===' | Out-File $o -Append -Encoding UTF8

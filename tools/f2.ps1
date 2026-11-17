$o='C:\Users\Public\f2.txt'
Remove-Item $o -EA 0
$d='C:\Users\Public\Sideloadly'
Get-ChildItem $d -Recurse -Include *.exe -EA 0 | ForEach-Object { [string]$_.Name | Out-File $o -Append -Encoding UTF8 }
Add-Content $o '--- sub ---'
Get-ChildItem $d -Directory -EA 0 | ForEach-Object { [string]$_.Name | Out-File $o -Append -Encoding UTF8 }

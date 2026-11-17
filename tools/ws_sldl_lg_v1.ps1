$out = 'C:\Users\Public\ws_sldl_lg.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$dirs = @('C:\Users\Public\Sideloadly', "$env:APPDATA\Sideloadly", "$env:LOCALAPPDATA\Sideloadly", "$env:TEMP")
foreach ($d in $dirs) {
  A ('--- DIR ' + $d + ' exists=' + (Test-Path $d))
  if (Test-Path $d) {
    Get-ChildItem -Path $d -Filter *.txt -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { A ('  txt: ' + $_.FullName + ' ' + $_.Length) }
    Get-ChildItem -Path $d -Filter *.log -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { A ('  log: ' + $_.FullName + ' ' + $_.Length) }
  }
}
# newest files in Sideloadly dir
if (Test-Path 'C:\Users\Public\Sideloadly') {
  A '--- newest in Sideloadly dir'
  Get-ChildItem 'C:\Users\Public\Sideloadly' -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12 | ForEach-Object { A ('  ' + $_.LastWriteTime.ToString('HH:mm:ss') + ' ' + $_.Name + ' ' + $_.Length) }
}
A '--- done ---'

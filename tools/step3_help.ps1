# step3_help.ps1 -- show iloader help. ASCII only.
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'
& $exe --help 2>&1 | ForEach-Object { Write-Output $_ }
Write-Output 'DONE'

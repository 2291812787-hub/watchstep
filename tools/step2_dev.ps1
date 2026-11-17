# step2_dev.ps1 -- list devices only. ASCII only.
$exe = 'C:\Users\Public\iwatch\iloader-cli.exe'
& $exe --list-devices 2>&1 | ForEach-Object { Write-Output $_ }
Write-Output 'DONE'

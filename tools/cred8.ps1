Add-Type -Path C:\Users\Public\wcred4.cs
$t = '459ef4bfefafe1210d2b4ba79b99a71eab656f4d3a5320208408f12aa3032721/key.io.github.andreysemjonov.iloader'
$r = [wc]::Run($t, 'C:\Users\Public\sl_key.der', 'C:\Users\Public\iloader_key_old.der')
$r | Out-File -FilePath C:\Users\Public\cred6.txt -Encoding UTF8
Write-Output $r

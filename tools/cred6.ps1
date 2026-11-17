$cs = 'C:\Users\Public\wcred.cs'
Add-Type -Path $cs
$t = '459ef4bfefafe1210d2b4ba79b99a71eab656f4d3a5320208408f12aa3032721/key.io.github.andreysemjonov.iloader'
$old = [wc]::Read($t)
if ($old -eq $null) { 'READFAIL'; exit 1 }
[IO.File]::WriteAllBytes('C:\Users\Public\iloader_key_old.der', $old.blob)
'BACKUP bytes=' + $old.blob.Length + ' user=' + $old.user
$new = [IO.File]::ReadAllBytes('C:\Users\Public\sl_key.der')
'NEWKEY bytes=' + $new.Length
$ok = [wc]::Write($t, $old.user, $new)
'WRITE ok=' + $ok
$chk = [wc]::Read($t)
'VERIFY bytes=' + $chk.blob.Length

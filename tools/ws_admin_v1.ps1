# ws_admin_v1.ps1 -- are we elevated? where did Sideloadly go? ASCII only.
$out = 'C:\Users\Public\ws_admin_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
A ('user=' + $id.Name)
A ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

A '--- registry uninstall entries ---'
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    Get-ItemProperty $k -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Sideload' } |
        ForEach-Object { A ('  ' + $_.DisplayName + ' | ' + $_.DisplayVersion + ' | ' + $_.InstallLocation) }
}

A '--- any Sideloadly.exe on disk (C: only, shallow) ---'
$hits = Get-ChildItem -Path 'C:\' -Filter 'Sideloadly*.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 10
foreach ($h in $hits) { A ('  ' + $h.FullName + ' ' + $h.Length + ' ' + $h.LastWriteTime.ToString('HH:mm')) }

A '--- temp extract dirs ---'
Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Sideload|ns[A-Za-z0-9]{3}|is-[A-Z0-9]+' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
    ForEach-Object { A ('  ' + $_.LastWriteTime.ToString('HH:mm') + ' ' + $_.FullName) }
A '--- done ---'

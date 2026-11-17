# ws_sldl_ipa_v1.ps1 -- restart Sideloadly preloading the IPA. ASCII only.
$out = 'C:\Users\Public\ws_sldl_ipa_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
$dir = 'C:\Users\Public\Sideloadly'
$exe = Join-Path $dir 'sideloadly.exe'
$ipa = 'C:\Users\Public\WatchStep5.ipa'

Get-Process -Name 'sideloadly' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$p = Start-Process -FilePath $exe -ArgumentList ('"' + $ipa + '"') -WorkingDirectory $dir -PassThru
A ('launched pid=' + $p.Id + ' with ipa')
Start-Sleep -Seconds 14

Add-Type -Namespace W3 -Name U3 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
$p.Refresh()
$h = $p.MainWindowHandle
A ('hwnd=' + $h)
if ($h -ne [IntPtr]::Zero) { [void][W3.U3]::ShowWindow($h, 3); [void][W3.U3]::SetForegroundWindow($h); A 'fg=ok' } else { A 'fg=none' }
A '--- done ---'

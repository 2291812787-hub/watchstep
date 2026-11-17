# ws_sldl_launch_v1.ps1 -- launch Sideloadly GUI and bring to front. ASCII only.
$out = 'C:\Users\Public\ws_sldl_launch_v1.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }
A ('=== ' + (Get-Date -Format 'HH:mm:ss'))

$dir = 'C:\Users\Public\Sideloadly'
$exe = Join-Path $dir 'sideloadly.exe'
$ipa = 'C:\Users\Public\WatchStep5.ipa'
A ('exe=' + (Test-Path $exe) + ' ipa=' + (Test-Path $ipa))

# kill any leftover instance
Get-Process -Name 'sideloadly','sideloadlydaemon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
A ('launched pid=' + $p.Id)
Start-Sleep -Seconds 12

# bring forward
Add-Type -Namespace W2 -Name U2 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
$p.Refresh()
$h = $p.MainWindowHandle
A ('hwnd=' + $h)
if ($h -ne [IntPtr]::Zero) {
    [void][W2.U2]::ShowWindow($h, 3)
    [void][W2.U2]::SetForegroundWindow($h)
    A 'fg=ok'
} else { A 'fg=none' }

$ps = Get-Process -Name 'sideloadly','sideloadlydaemon' -ErrorAction SilentlyContinue
foreach ($x in $ps) { A ('  proc ' + $x.Name + ' pid=' + $x.Id + ' hwnd=' + $x.MainWindowHandle) }
A '--- done ---'

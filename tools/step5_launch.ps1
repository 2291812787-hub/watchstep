# step5_launch.ps1 -- open interactive install window for WatchStep5.ipa, bring to front. ASCII only.
$ErrorActionPreference = 'Continue'
$out = 'C:\Users\Public\step5_launch.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }

$dir = 'C:\Users\Public\iwatch'
$exe = Join-Path $dir 'iloader-cli.exe'
$ipa = 'C:\Users\Public\WatchStep5.ipa'

A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
if (-not (Test-Path $ipa)) { A '  IPA_MISSING'; A 'DONE'; exit 2 }
A ('  IPA bytes=' + (Get-Item $ipa).Length)

$u = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_05AC' }
A ('  USB_COUNT=' + @($u).Count)

# close any leftover iloader process so a fresh login window appears
Get-Process -Name 'iloader-cli' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$a = '/k chcp 65001 >nul & cd /d "' + $dir + '" & iloader-cli.exe "' + $ipa + '" & echo. & echo ==== WINDOW DONE ==== & pause'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList $a -PassThru
A ('  cmd_pid=' + $p.Id)
Start-Sleep -Seconds 3

# bring the window to the foreground
Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'
try {
    $h = $p.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [void][W.U]::ShowWindow($h, 9)
        [void][W.U]::SetForegroundWindow($h)
        A ('  fg_handle=' + $h)
    } else {
        Start-Sleep -Seconds 2
        $p.Refresh()
        $h = $p.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) { [void][W.U]::ShowWindow($h, 9); [void][W.U]::SetForegroundWindow($h); A ('  fg_handle_late=' + $h) } else { A '  fg_handle=NONE' }
    }
} catch { A ('  FG_FAIL ' + $_.Exception.Message) }

A '  RESULT=LAUNCHED'
A 'DONE'

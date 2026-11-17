# step7_launch.ps1 -- open install window for WatchStep6.ipa. ASCII only.
$ErrorActionPreference = 'Continue'
$out = 'C:\Users\Public\step7_launch.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function A($m) { [string]$m | Out-File -FilePath $out -Append -Encoding UTF8 }

$dir = 'C:\Users\Public\iwatch'
$ipa = 'C:\Users\Public\WatchStep6.ipa'

A ('=== ' + (Get-Date -Format 'HH:mm:ss'))
if (-not (Test-Path $ipa)) { A '  IPA_MISSING'; A 'DONE'; exit 2 }
A ('  IPA bytes=' + (Get-Item $ipa).Length)

$u = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_05AC' }
A ('  USB_COUNT=' + @($u).Count)

Get-Process -Name 'iloader-cli' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$a = '/k chcp 65001 >nul & cd /d "' + $dir + '" & iloader-cli.exe "' + $ipa + '" & echo. & echo ==== WINDOW DONE ==== & pause'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList $a -PassThru
A ('  cmd_pid=' + $p.Id)
Start-Sleep -Seconds 4

Add-Type -Namespace W7 -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
try {
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [void][W7.U]::ShowWindow($h, 9)
        [void][W7.U]::SetForegroundWindow($h)
        A ('  fg_handle=' + $h)
    } else { A '  fg_handle=NONE' }
} catch { A ('  FG_FAIL ' + $_.Exception.Message) }

A '  RESULT=LAUNCHED'
A 'DONE'

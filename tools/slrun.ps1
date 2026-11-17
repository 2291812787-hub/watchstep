Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
"@
$out = "C:\Users\Public\sl2.txt"
$lines = @("=== sl2 " + (Get-Date -Format HH:mm:ss))
$exe = 'C:\Users\Public\Sideloadly\sideloadly.exe'
$ipa = 'C:\Users\Public\WatchStep6.ipa'
Start-Process -FilePath $exe -ArgumentList ('"' + $ipa + '"')
Start-Sleep -Seconds 25
$p = Get-Process sideloadly -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) {
  $lines += ("pid=" + $p.Id)
  $h = $p.MainWindowHandle
  $lines += ("hwnd=" + $h)
  if ($h -ne 0) { [W2]::ShowWindow($h, 9) | Out-Null; [W2]::SetForegroundWindow($h) | Out-Null }
} else { $lines += "NO_PROC" }
$lines | Out-File -FilePath $out -Encoding UTF8
$lines -join "`n"

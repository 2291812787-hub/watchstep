Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
}
"@
Get-Process | Where-Object { $_.MainWindowTitle -like "*WATCHSTEP*" } | ForEach-Object { [W]::ShowWindow($_.MainWindowHandle,9) | Out-Null; [W]::SetForegroundWindow($_.MainWindowHandle) | Out-Null; Write-Output ("FG pid=" + $_.Id) }

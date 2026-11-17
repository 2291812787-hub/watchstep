$o='C:\Users\Public\fg3.txt'
Remove-Item $o -EA 0
$sig=@'
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
'@
Add-Type -TypeDefinition $sig -EA 0
$p=Get-Process sideloadly -EA 0 | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($p) {
  [W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
  [W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Add-Content $o ('fg pid=' + $p.Id)
} else {
  Add-Content $o 'no window'
}
Start-Sleep -Seconds 2
Add-Content $o 'DONE'

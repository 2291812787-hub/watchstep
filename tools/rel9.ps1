$out='C:\Users\Public\rel9.txt'
$ipa='C:\Users\Public\WatchStep6.ipa'
"=== rel9 $((Get-Date).ToString('HH:mm:ss'))" | Out-File $out -Encoding UTF8
if (Test-Path $ipa) {
  $f=Get-Item $ipa
  "ipa bytes=$($f.Length)" | Out-File $out -Append -Encoding UTF8
  "ipa sha=$((Get-FileHash $ipa -Algorithm SHA256).Hash)" | Out-File $out -Append -Encoding UTF8
} else {
  "IPA MISSING" | Out-File $out -Append -Encoding UTF8
}
Get-Process iloader-cli -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$cmd = '/k chcp 65001 >nul & cd /d C:\Users\Public\iwatch & title WATCHSTEP-SIGN & iloader-cli.exe "C:\Users\Public\WatchStep6.ipa"'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmd -PassThru
Start-Sleep -Seconds 18
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class FG2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@ -ErrorAction SilentlyContinue
if ($p.MainWindowHandle -ne 0) {
  [FG2]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
  [FG2]::BringWindowToTop($p.MainWindowHandle) | Out-Null
  [FG2]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
}
"cmd pid=$($p.Id) hwnd=$($p.MainWindowHandle)" | Out-File $out -Append -Encoding UTF8
Get-Process iloader-cli -ErrorAction SilentlyContinue | ForEach-Object { "iloader pid=$($_.Id)" | Out-File $out -Append -Encoding UTF8 }
"=== END" | Out-File $out -Append -Encoding UTF8

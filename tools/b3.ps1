$o='C:\Users\Public\b3.txt'
Remove-Item $o -EA 0
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
'@
$p = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($p) {
  [W.U]::ShowWindow($p.MainWindowHandle, 3) | Out-Null
  [W.U]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Add-Content $o ('FG chrome ' + $p.Id)
  Start-Sleep -Seconds 2
  # open the apple page again in that window
  Start-Process 'https://developer.apple.com/account/resources/certificates/list'
  Start-Sleep -Seconds 6
  Add-Content $o 'OPENED'
} else { Add-Content $o 'NO_CHROME' }

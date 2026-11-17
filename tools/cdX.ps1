Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class C {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool AttachConsole(uint p);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool FreeConsole();
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateFileW(string n,uint a,uint s,IntPtr sa,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern bool ReadConsoleOutputCharacterW(IntPtr h,char[] b,uint l,short x,short y,out uint r);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 public static string Dump(uint pid){
  var sb=new StringBuilder();
  FreeConsole();
  if(!AttachConsole(pid)) return "ATTACH_FAIL "+Marshal.GetLastWin32Error();
  IntPtr h=CreateFileW("CONOUT$",0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
  if(h==new IntPtr(-1)){FreeConsole();return "OPEN_FAIL";}
  char[] buf=new char[400];
  for(short y=0;y<600;y++){
   uint got=0;
   if(!ReadConsoleOutputCharacterW(h,buf,400,0,y,out got)||got==0) break;
   string line=new string(buf,0,(int)got).TrimEnd();
   if(line.Trim().Length>0) sb.AppendLine(line);
  }
  CloseHandle(h); FreeConsole();
  return sb.ToString();
 }
}
"@
$T='WATCHSTEP-SIGN'
$w=Get-Process | Where-Object { $_.MainWindowTitle -like "*$T*" } | Select-Object -First 1
$out = "NO_WINDOW"
if($w){ $out = "PID=" + $w.Id + "`r`n" + [C]::Dump([uint32]$w.Id) }
$out | Out-File -FilePath C:\Users\Public\cdumpX.txt -Encoding UTF8

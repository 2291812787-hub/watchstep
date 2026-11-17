$t = "459ef4bfefafe1210d2b4ba79b99a71eab656f4d3a5320208408f12aa3032721/key.io.github.andreysemjonov.iloader"
$sig = @"
using System;
using System.Runtime.InteropServices;
public class C2 {
 public struct CREDENTIAL { public int Flags; public int Type; public IntPtr TargetName; public IntPtr Comment; public long LastWritten; public int BlobSize; public IntPtr Blob; public int Persist; public int AttrCount; public IntPtr Attrs; public IntPtr Alias; public int UserNameLen; }
 [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
 public static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
 [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr c);
}
"@
Add-Type -TypeDefinition $sig -Language CSharp
$p = [IntPtr]::Zero
$ok = [C2]::CredReadW($t, 1, 0, [ref]$p)
"OK=$ok ERR=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
if ($ok) {
  $c = [Runtime.InteropServices.Marshal]::PtrToStructure($p, [type][C2+CREDENTIAL])
  "BLOBSIZE=$($c.BlobSize)"
  $b = New-Object byte[] $c.BlobSize
  [Runtime.InteropServices.Marshal]::Copy($c.Blob, $b, 0, $c.BlobSize)
  [IO.File]::WriteAllBytes('C:\Users\Public\iloader_key.bin', $b)
  "HEAD=" + ([Text.Encoding]::ASCII.GetString($b[0..([Math]::Min(60,$c.BlobSize-1))]) -replace "[^ -~]",".")
  [C2]::CredFree($p)
}

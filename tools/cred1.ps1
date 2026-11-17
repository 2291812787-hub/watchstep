Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Cred {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags; public uint Type;
    public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize; public IntPtr CredentialBlob;
    public uint Persist; public uint AttributeCount;
    public IntPtr Attributes; public string TargetAlias; public string UserName;
  }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
  [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr buf);
}
"@
$out = @()
$list = cmdkey /list 2>&1 | Select-String "iloader|sideloadly" -Context 0,0
foreach ($l in $list) { $out += "CMDKEY: $l" }
foreach ($t in @("LegacyGeneric:target=key.io.github.andreysemjonov.iloader")) {
  $p = [IntPtr]::Zero
  if ([Cred]::CredReadW($t, 1, 0, [ref]$p)) {
    $c = [System.Runtime.InteropServices.Marshal]::PtrToStructure($p, [type][Cred+CREDENTIAL])
    $blob = New-Object byte[] $c.CredentialBlobSize
    [System.Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $blob, 0, $c.CredentialBlobSize)
    $out += "TARGET=$t USER=$($c.UserName) SIZE=$($c.CredentialBlobSize)"
    $s = [System.Text.Encoding]::ASCII.GetString($blob)
    $out += "HEAD=" + ($s.Substring(0, [Math]::Min(60, $s.Length)) -replace "`r|`n", " ")
    [Cred]::CredFree($p)
  } else { $out += "READ FAIL $t code=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
}
$out | Out-File -Encoding UTF8 C:\Users\Public\cred1.txt

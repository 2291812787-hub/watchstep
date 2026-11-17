using System;
using System.Runtime.InteropServices;
public class WC {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CRED {
    public int Flags; public int Type; public string Target; public string Comment;
    public long LastWritten; public int BlobSize; public IntPtr Blob;
    public int Persist; public int AttrCount; public IntPtr Attrs;
    public string User; public string Pass;
  }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CredReadW(string t, int type, int flags, out IntPtr cred);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CredWriteW(ref CRED cred, int flags);
  [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr p);
}

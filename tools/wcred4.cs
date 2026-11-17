using System;
using System.IO;
using System.Runtime.InteropServices;
public class WC {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CRED {
    public int Flags; public int Type; public string Target; public string Comment;
    public long LastWritten; public int BlobSize; public IntPtr Blob;
    public int Persist; public int AttrCount; public IntPtr Attrs;
    public string User;
  }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredReadW(string t, int type, int flags, out IntPtr p);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredWriteW(ref CRED c, int flags);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
  static string err = "";
  public static byte[] Rd(string t, out string user) {
    user = null; IntPtr p;
    if (!CredReadW(t, 1, 0, out p)) { err = "read:" + Marshal.GetLastWin32Error(); return null; }
    CRED c = (CRED)Marshal.PtrToStructure(p, typeof(CRED));
    byte[] b = new byte[c.BlobSize];
    Marshal.Copy(c.Blob, b, 0, c.BlobSize);
    user = c.User; CredFree(p); return b;
  }
  public static bool Wr(string t, string user, byte[] blob) {
    CRED c = new CRED();
    c.Type = 1; c.Persist = 2; c.Target = t; c.User = user; c.BlobSize = blob.Length;
    IntPtr p = Marshal.AllocHGlobal(blob.Length);
    Marshal.Copy(blob, 0, p, blob.Length); c.Blob = p;
    bool ok = CredWriteW(ref c, 0);
    if (!ok) err = "write:" + Marshal.GetLastWin32Error();
    Marshal.FreeHGlobal(p); return ok;
  }
  public static string Swap(string t, string newKey, string backup) {
    string u; byte[] old = Rd(t, out u);
    if (old == null) return "FATAL " + err;
    File.WriteAllBytes(backup, old);
    byte[] nk = File.ReadAllBytes(newKey);
    bool ok = Wr(t, u, nk);
    string s = "old=" + old.Length + " new=" + nk.Length + " user=" + u + " ok=" + ok;
    string u2; byte[] chk = Rd(t, out u2);
    s += " verify=" + (chk == null ? -1 : chk.Length);
    return s + " " + err;
  }
}

using System;
using System.Runtime.InteropServices;

namespace CodexQuotaMonitor
{
    public static class NativeIconMethodsV1
    {
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}

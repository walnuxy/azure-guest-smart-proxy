param(
    [Parameter(Mandatory=$true)][string]$Server,
    [string]$Bypass = '<local>'
)
$ErrorActionPreference = 'Stop'
if (-not ('SmartProxy.PerConnection' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace SmartProxy {
    public static class PerConnection {
        [StructLayout(LayoutKind.Sequential)]
        private struct Options {
            public int Size;
            public IntPtr Connection;
            public int Count;
            public int Error;
            public IntPtr Values;
        }
        [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
        private static extern bool SetOptions(IntPtr handle, int option, ref Options values, int length);
        [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
        private static extern bool Notify(IntPtr handle, int option, IntPtr buffer, int length);
        public static void Set(string server, string bypass) {
            int size = IntPtr.Size == 8 ? 16 : 12;
            int valueOffset = IntPtr.Size == 8 ? 8 : 4;
            IntPtr values = Marshal.AllocHGlobal(size * 3);
            IntPtr serverText = Marshal.StringToHGlobalUni(server);
            IntPtr bypassText = Marshal.StringToHGlobalUni(bypass);
            try {
                for (int i=0; i<size*3; i++) Marshal.WriteByte(values, i, 0);
                Marshal.WriteInt32(values, 0, 1); // INTERNET_PER_CONN_FLAGS
                Marshal.WriteInt32(values, valueOffset, 3); // DIRECT | PROXY
                Marshal.WriteInt32(values, size, 2); // INTERNET_PER_CONN_PROXY_SERVER
                Marshal.WriteIntPtr(values, size + valueOffset, serverText);
                Marshal.WriteInt32(values, size*2, 3); // INTERNET_PER_CONN_PROXY_BYPASS
                Marshal.WriteIntPtr(values, size*2 + valueOffset, bypassText);
                Options options = new Options { Size=Marshal.SizeOf(typeof(Options)), Count=3, Values=values };
                if (!SetOptions(IntPtr.Zero, 75, ref options, options.Size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (!Notify(IntPtr.Zero, 39, IntPtr.Zero, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (!Notify(IntPtr.Zero, 37, IntPtr.Zero, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                Marshal.FreeHGlobal(values);
                Marshal.FreeHGlobal(serverText);
                Marshal.FreeHGlobal(bypassText);
            }
        }
    }
}
'@
}
[SmartProxy.PerConnection]::Set($Server, $Bypass)

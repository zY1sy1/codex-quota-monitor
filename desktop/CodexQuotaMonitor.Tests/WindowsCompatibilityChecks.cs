using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml.Linq;
using CodexQuotaMonitor.Desktop;

namespace CodexQuotaMonitor.Tests;

internal static class WindowsCompatibilityChecks
{
    public static void Run(string root, Action<string, Action> test)
    {
        foreach (var build in new[] { 19041, 19044, 19045, 22000, 26100, 26300 })
            test("Windows support build " + build, () => Check(WindowsCompatibility.IsSupported(true, new Version(10, 0, build)), "A supported Windows build was rejected."));
        test("older Windows builds are rejected", () =>
        {
            Check(!WindowsCompatibility.IsSupported(true, new Version(10, 0, 19040)), "Pre-2004 Windows was accepted.");
            Check(!WindowsCompatibility.IsSupported(true, new Version(6, 3, 9600)), "Windows 8.1 was accepted.");
            Check(!WindowsCompatibility.IsSupported(false, new Version(10, 0, 19045)), "A non-Windows OS was accepted.");
        });
        test("opaque rendering fallback policy", () =>
        {
            Check(!WindowsCompatibility.UseTransparency(0, true, false, true), "Software rendering retained effects.");
            Check(!WindowsCompatibility.UseTransparency(2, false, false, true), "Disabled transparency was ignored.");
            Check(!WindowsCompatibility.UseTransparency(2, true, true, true), "High contrast retained effects.");
            Check(!WindowsCompatibility.UseTransparency(2, true, false, false), "Failed blur retained transparency.");
            Check(WindowsCompatibility.UseTransparency(2, true, false, true), "Available transparency was disabled.");
        });
        test("unavailable composition APIs do not abort startup", () =>
        {
            Check(!WindowsCompatibility.TryEnableBlur(IntPtr.Zero), "An invalid handle was accepted.");
            Check(!WindowsCompatibility.TryEnableBlur(new IntPtr(1), _ => throw new EntryPointNotFoundException()), "Missing API was not handled.");
            Check(!WindowsCompatibility.TryEnableBlur(new IntPtr(1), _ => throw new DllNotFoundException()), "Missing DLL was not handled.");
            Check(!WindowsCompatibility.TryEnableBlur(new IntPtr(1), _ => false), "A failed native call was accepted.");
        });
        test("compiled executable declares Windows 10 and per-monitor DPI", () =>
        {
            var executable = Path.Combine(root, "desktop", "CodexQuotaMonitor.Desktop", "bin", "Release", "net8.0-windows", "win-x64", "CodexQuotaMonitor.exe");
            var manifest = XDocument.Parse(ReadManifest(executable));
            Check(manifest.Descendants().Any(e => e.Name.LocalName == "supportedOS" && string.Equals((string?)e.Attribute("Id"), "{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}", StringComparison.OrdinalIgnoreCase)), "Windows 10 manifest was not embedded.");
            Check(manifest.Descendants().Any(e => e.Name.LocalName == "dpiAware" && e.Value == "true/pm"), "DPI fallback was not embedded.");
            Check(manifest.Descendants().Any(e => e.Name.LocalName == "dpiAwareness" && e.Value.StartsWith("PerMonitorV2", StringComparison.Ordinal)), "Per-monitor DPI was not embedded.");
            Check(manifest.Descendants().Any(e => e.Name.LocalName == "requestedExecutionLevel" && (string?)e.Attribute("level") == "asInvoker"), "The executable requested elevation.");
        });
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool FreeLibrary(IntPtr module);
    private static string ReadManifest(string path)
    {
        var module = LoadLibraryEx(path, IntPtr.Zero, 2 | 0x20);
        if (module == IntPtr.Zero) throw new IOException("The executable could not be inspected.");
        try
        {
            var resource = FindResource(module, new IntPtr(1), new IntPtr(24));
            if (resource == IntPtr.Zero) throw new InvalidDataException("The executable manifest is missing.");
            var bytes = new byte[SizeofResource(module, resource)];
            Marshal.Copy(LockResource(LoadResource(module, resource)), bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF');
        }
        finally { FreeLibrary(module); }
    }
}

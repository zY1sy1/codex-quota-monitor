using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public static class NativeSecrets
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr handle);
    public static string Protect(string plain) => plain.Length == 0 ? "" : Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(plain), true));
    public static string Unprotect(string cipher)
    {
        if (cipher.Length == 0) return "";
        byte[]? result = null;
        try { result = Transform(Convert.FromBase64String(cipher), false); return Encoding.UTF8.GetString(result); }
        catch (FormatException) { throw new CryptographicException("凭据解密失败。"); }
        finally { if (result is not null) CryptographicOperations.ZeroMemory(result); }
    }
    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new Blob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) }; var output = new Blob();
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            var success = protect ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new CryptographicException(protect ? "凭据加密失败。" : "凭据解密失败。");
            var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            Marshal.Copy(new byte[input.Length], 0, input.Data, input.Length); Marshal.FreeHGlobal(input.Data); CryptographicOperations.ZeroMemory(bytes);
            if (output.Data != IntPtr.Zero) { Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length); LocalFree(output.Data); }
        }
    }
}

public sealed class MonitorInstance : IDisposable
{
    private readonly Mutex mutex;
    public bool Primary { get; }
    public EventWaitHandle Activate { get; }
    public EventWaitHandle Exit { get; }
    public MonitorInstance(string prefix)
    {
        if (!prefix.StartsWith("Local\\", StringComparison.Ordinal) || prefix.EndsWith('\\') || prefix.Contains('\0')) throw new ArgumentException("Invalid instance prefix.");
        mutex = new Mutex(false, prefix);
        try { Primary = mutex.WaitOne(0); } catch (AbandonedMutexException) { Primary = true; }
        Activate = new EventWaitHandle(false, EventResetMode.AutoReset, prefix + ".Activate");
        Exit = new EventWaitHandle(false, EventResetMode.AutoReset, prefix + ".Exit");
    }
    public void Dispose() { Activate.Dispose(); Exit.Dispose(); if (Primary) mutex.ReleaseMutex(); mutex.Dispose(); }
}

public sealed class NativeTray : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyData
    {
        public uint Size; public IntPtr Window; public uint Id; public uint Flags; public uint Callback; public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State; public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Title;
        public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyData data);
    [DllImport("user32.dll")] private static extern IntPtr CreateIcon(IntPtr instance, int width, int height, byte planes, byte bits, byte[] mask, byte[] pixels);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string text);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr window);
    private readonly HwndSource source;
    private readonly ContextMenu menu;
    private readonly Action toggle;
    private readonly Action resume;
    private readonly uint explorerRestart = RegisterWindowMessage("TaskbarCreated");
    private NotifyData data;
    private string color = "";
    public NativeTray(ContextMenu menu, Action toggle, Action resume)
    {
        this.menu = menu; this.toggle = toggle; this.resume = resume;
        source = new HwndSource(new HwndSourceParameters("Codex Quota Monitor") { Width = 0, Height = 0, WindowStyle = unchecked((int)0x80000000) });
        source.AddHook(Hook);
        data = new NotifyData { Size = (uint)Marshal.SizeOf<NotifyData>(), Window = source.Handle, Id = 1, Flags = 1 | 2 | 4, Callback = 0x8001, Tip = "Codex 额度监视器", Info = "", Title = "" };
        Update("#AFB8CB", "正在连接"); Shell_NotifyIcon(0, ref data);
    }
    public void Update(string nextColor, string text)
    {
        if (text.Length > 120) text = text[..120];
        bool changed = data.Tip != text || color != nextColor;
        data.Tip = text;
        if (color != nextColor)
        {
            var c = (Color)ColorConverter.ConvertFromString(nextColor); var pixels = new byte[16 * 16 * 4];
            for (var y = 0; y < 16; y++) for (var x = 0; x < 16; x++)
            {
                var distance = Math.Sqrt(Math.Pow(x - 7.5, 2) + Math.Pow(y - 7.5, 2));
                var alpha = (byte)Math.Clamp((7.4 - distance) * 255, 0, 255); var at = (y * 16 + x) * 4;
                pixels[at] = (byte)(c.B * alpha / 255); pixels[at + 1] = (byte)(c.G * alpha / 255); pixels[at + 2] = (byte)(c.R * alpha / 255); pixels[at + 3] = alpha;
            }
            var icon = CreateIcon(IntPtr.Zero, 16, 16, 1, 32, new byte[32], pixels);
            if (icon != IntPtr.Zero) { var old = data.Icon; data.Icon = icon; if (old != IntPtr.Zero) DestroyIcon(old); }
            color = nextColor;
        }
        if (changed) Shell_NotifyIcon(1, ref data);
    }
    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if ((uint)message == explorerRestart) Shell_NotifyIcon(0, ref data);
        if (message == 0x218 && wParam.ToInt64() is 7 or 18) resume();
        if (message == 0x8001)
        {
            if (lParam.ToInt32() == 0x203) toggle();
            if (lParam.ToInt32() == 0x205) { SetForegroundWindow(hwnd); menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint; menu.IsOpen = true; }
            handled = true;
        }
        return IntPtr.Zero;
    }
    public void Dispose() { menu.IsOpen = false; Shell_NotifyIcon(2, ref data); if (data.Icon != IntPtr.Zero) DestroyIcon(data.Icon); source.RemoveHook(Hook); source.Dispose(); }
}

public static class WindowPosition
{
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public int Flags; }
    private delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    public static void Place(Window window, MonitorSettings settings)
    {
        var areas = new List<Rect>(); var matrix = PresentationSource.FromVisual(window)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(monitor, ref info))
            {
                var topLeft = matrix.Transform(new Point(info.Work.Left, info.Work.Top)); var bottomRight = matrix.Transform(new Point(info.Work.Right, info.Work.Bottom));
                areas.Add(new Rect(topLeft, bottomRight));
            }
            return true;
        }, IntPtr.Zero);
        if (areas.Count == 0) areas.Add(SystemParameters.WorkArea);
        var position = settings.Position(settings.Mode); var width = window.ActualWidth > 0 ? window.ActualWidth : window.Width;
        var height = window.ActualHeight > 0 ? window.ActualHeight : 300;
        var left = position["Left"].Number(); var top = position["Top"].Number();
        var area = areas.FirstOrDefault(a => left.HasValue && top.HasValue && a.IntersectsWith(new Rect(left.Value, top.Value, width, height)));
        if (area.IsEmpty || area.Width <= 0) area = areas[0];
        window.Left = Math.Clamp(left ?? area.Right - width - 24, area.Left, Math.Max(area.Left, area.Right - width));
        window.Top = Math.Clamp(top ?? area.Top + 24, area.Top, Math.Max(area.Top, area.Bottom - Math.Min(height, area.Height)));
        window.MaxHeight = Math.Max(120, area.Height - 16);
    }
    public static void Save(Window window, MonitorSettings settings)
    { var position = settings.Position(settings.Mode); position["Left"] = window.Left; position["Top"] = window.Top; }
}

public static class StartupShortcut
{
    public static void Set(bool enabled, string executable)
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Codex Quota Monitor.lnk");
        if (!enabled) { if (File.Exists(path)) File.Delete(path); return; }
        object? shell = null; object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("无法创建启动快捷方式。"));
            dynamic com = shell!; shortcut = com.CreateShortcut(path); dynamic link = shortcut;
            link.TargetPath = executable; link.WorkingDirectory = Path.GetDirectoryName(executable); link.Arguments = "";
            link.Description = "Codex 额度监视器"; link.IconLocation = executable + ",0"; link.Save();
        }
        finally { if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut); if (shell is not null) Marshal.FinalReleaseComObject(shell); }
    }
    public static void Open(string target) => Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
}

using System.Runtime.InteropServices;

namespace CodexQuotaMonitor.Desktop;

public static class WindowsCompatibility
{
    public const int MinimumBuild = 19041;
    public const string Requirement = "需要 Windows 10 x64（2004 / build 19041 或更高版本）或 Windows 11 x64。";
    public static bool IsSupported(bool isWindows, Version version) => isWindows && version.Major == 10 && version.Build >= MinimumBuild;
    public static bool UseTransparency(int renderingTier, bool transparencyEnabled, bool highContrast, bool blurApplied)
        => renderingTier > 0 && transparencyEnabled && !highContrast && blurApplied;

    public static bool TryEnableBlur(IntPtr window, Func<IntPtr, bool>? apply = null)
    {
        if (window == IntPtr.Zero) return false;
        try { return (apply ?? CodexQuotaMonitor.Theme.NativeMethods.EnableBlur)(window); }
        catch (EntryPointNotFoundException) { return false; }
        catch (DllNotFoundException) { return false; }
        catch (ExternalException) { return false; }
    }
}

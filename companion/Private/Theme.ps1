function Get-MonitorThemePalette {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Light', 'Dark')]
        [string]$Theme
    )

    if ($Theme -eq 'Light') {
        return [ordered]@{
            Surface = '#E6F4EFEA'
            SurfaceStrong = '#D9EEE7E1'
            TextPrimary = '#FF201F1D'
            TextSecondary = '#FF6F6B67'
            Accent = '#FF4DADB3'
            Track = '#667E8588'
            Separator = '#40716D68'
            Shadow = '#30000000'
            Warning = '#FFE0A43A'
            Danger = '#FFD65C5C'
        }
    }

    return [ordered]@{
        Surface = '#E6323A4C'
        SurfaceStrong = '#D93A4358'
        TextPrimary = '#FFF4F3F1'
        TextSecondary = '#FFAFB8CB'
        Accent = '#FF58C2C7'
        Track = '#664D566A'
        Separator = '#4D707A90'
        Shadow = '#66000000'
        Warning = '#FFF1B84B'
        Danger = '#FFFF6B6B'
    }
}

function ConvertTo-MonitorThemeBrush {
    param([Parameter(Mandatory)][string]$Color)
    [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-MonitorWindowTheme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][object]$Controls,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme
    )

    Add-Type -AssemblyName PresentationFramework
    $palette = Get-MonitorThemePalette -Theme $Theme
    $Controls.RootBorder.Background = ConvertTo-MonitorThemeBrush $palette.Surface
    $Controls.RootBorder.BorderBrush = ConvertTo-MonitorThemeBrush $palette.Separator
    $Controls.TitleText.Foreground = ConvertTo-MonitorThemeBrush $palette.TextPrimary
    $Controls.FreshnessText.Foreground = ConvertTo-MonitorThemeBrush $palette.TextSecondary
    $Controls.ConnectionDot.Background = ConvertTo-MonitorThemeBrush $palette.TextSecondary
    foreach ($name in @(
        'PinButton', 'ThemeButton', 'ModeButton', 'LayoutButton', 'HideButton', 'CloseButton',
        'OfficialTabButton', 'RelayTabButton'
    )) {
        if ($Controls.Contains($name)) {
            $Controls[$name].Foreground = ConvertTo-MonitorThemeBrush $palette.TextPrimary
            $Controls[$name].Background = [Windows.Media.Brushes]::Transparent
            $Controls[$name].BorderBrush = [Windows.Media.Brushes]::Transparent
        }
    }
    foreach ($name in @('OfficialExpander', 'RelayExpander')) {
        if ($Controls.Contains($name)) {
            $Controls[$name].Foreground = ConvertTo-MonitorThemeBrush $palette.TextPrimary
        }
    }
    $Window.Tag = $Theme
    return $palette
}

function Enable-MonitorWindowBlur {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [AllowNull()][scriptblock]$ApplyDwm = $null
    )

    if ($WindowHandle -eq [IntPtr]::Zero) {
        return $false
    }
    try {
        if ($null -ne $ApplyDwm) {
            return [bool](& $ApplyDwm $WindowHandle)
        }
        if (-not ('CodexQuotaMonitor.Theme.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
namespace CodexQuotaMonitor.Theme {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        private struct AccentPolicy {
            public int AccentState;
            public int AccentFlags;
            public int GradientColor;
            public int AnimationId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WindowCompositionAttributeData {
            public int Attribute;
            public IntPtr Data;
            public int SizeOfData;
        }

        [DllImport("user32.dll")]
        private static extern int SetWindowCompositionAttribute(
            IntPtr hwnd,
            ref WindowCompositionAttributeData data
        );

        public static bool EnableBlur(IntPtr hwnd) {
            AccentPolicy policy = new AccentPolicy { AccentState = 3 };
            int size = Marshal.SizeOf(policy);
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(policy, pointer, false);
                WindowCompositionAttributeData data = new WindowCompositionAttributeData {
                    Attribute = 19,
                    Data = pointer,
                    SizeOfData = size
                };
                return SetWindowCompositionAttribute(hwnd, ref data) != 0;
            }
            finally {
                Marshal.FreeHGlobal(pointer);
            }
        }
    }
}
'@
        }
        return [CodexQuotaMonitor.Theme.NativeMethods]::EnableBlur($WindowHandle)
    }
    catch {
        return $false
    }
}

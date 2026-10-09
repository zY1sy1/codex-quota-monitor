if (-not (Get-Command Initialize-MonitorNativeLibrary -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'NativeLibrary.ps1')
}

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
            AccentSoft = '#244DADB3'
            AccentPressed = '#3D4DADB3'
            SelectionSurface = '#D9E4E4DE'
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
        AccentSoft = '#2458C2C7'
        AccentPressed = '#3D58C2C7'
        SelectionSurface = '#D93C4B5F'
        Track = '#664D566A'
        Separator = '#4D707A90'
        Shadow = '#66000000'
        Warning = '#FFF1B84B'
        Danger = '#FFFF6B6B'
    }
}

function Get-SettingsThemePalette {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Light', 'Dark')]
        [string]$Theme
    )

    if ($Theme -eq 'Light') {
        return [ordered]@{
            Surface = '#FFF9FAFA'
            Sidebar = '#FFF1F5F5'
            SurfaceStrong = '#FFFFFFFF'
            TextPrimary = '#FF201F1D'
            TextSecondary = '#FF6F6B67'
            Accent = '#FF348186'
            AccentText = '#FFFFFFFF'
            Success = '#FF24757A'
            Selection = '#FFE2F0F0'
            Border = '#FF7A878C'
            Separator = '#FFD1D9DC'
            Hover = '#FFEAF3F3'
            Pressed = '#FFD9EAEA'
            Danger = '#FFB42323'
        }
    }

    return [ordered]@{
        Surface = '#FF323A4C'
        Sidebar = '#FF272E3D'
        SurfaceStrong = '#FF3A4358'
        TextPrimary = '#FFF4F3F1'
        TextSecondary = '#FFAFB8CB'
        Accent = '#FF58C2C7'
        AccentText = '#FF1F2832'
        Success = '#FF79D9DD'
        Selection = '#FF354D58'
        Border = '#FF8792A6'
        Separator = '#FF566074'
        Hover = '#FF3A4658'
        Pressed = '#FF425264'
        Danger = '#FFFFA0A0'
    }
}

function Set-SettingsWindowTheme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme
    )

    $palette = Get-SettingsThemePalette -Theme $Theme
    foreach ($entry in $palette.GetEnumerator()) {
        $Window.Resources["Settings$($entry.Key)Brush"] =
            ConvertTo-MonitorThemeBrush $entry.Value
    }
    $Window.Tag = $Theme
    return $palette
}

function ConvertTo-MonitorThemeBrush {
    param([Parameter(Mandatory)][string]$Color)
    [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-MonitorWindowRenderingCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RootBorder,
        [Parameter(Mandatory)][string]$SurfaceColor,
        [AllowNull()][Nullable[int]]$RenderingTier = $null,
        [AllowNull()][Nullable[bool]]$TransparencyEnabled = $null,
        [AllowNull()][Nullable[bool]]$HighContrast = $null
    )

    if ($null -eq $RenderingTier) { $RenderingTier = [Windows.Media.RenderCapability]::Tier -shr 16 }
    if ($null -eq $HighContrast) { $HighContrast = [Windows.SystemParameters]::HighContrast }
    if ($null -eq $TransparencyEnabled) {
        $TransparencyEnabled = $true
        $personalization = $null
        try {
            $personalization = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
                'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            )
            if ($null -ne $personalization) {
                $TransparencyEnabled = $personalization.GetValue('EnableTransparency', 1) -ne 0
            }
        }
        catch { }
        finally { if ($null -ne $personalization) { $personalization.Dispose() } }
    }
    # Windows 10, remote desktops and machines without GPU acceleration use
    # a readable opaque surface without the software-rendered shadow cost.
    if ($RenderingTier -eq 0 -or -not $TransparencyEnabled -or $HighContrast) {
        $opaqueColor = if ($SurfaceColor.Length -eq 9) { '#FF' + $SurfaceColor.Substring(3) } else { $SurfaceColor }
        $RootBorder.Background = ConvertTo-MonitorThemeBrush $opaqueColor
        $RootBorder.Effect = $null
    }
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
    $Window.Resources['QuotaFocusRingBrush'] = ConvertTo-MonitorThemeBrush $palette.Accent
    $Window.Resources['QuotaFocusHoverBrush'] = ConvertTo-MonitorThemeBrush $palette.AccentSoft
    $Window.Resources['QuotaFocusPressedBrush'] = ConvertTo-MonitorThemeBrush $palette.AccentPressed
    $Controls.RootBorder.Background = ConvertTo-MonitorThemeBrush $palette.Surface
    Set-MonitorWindowRenderingCompatibility -RootBorder $Controls.RootBorder -SurfaceColor $palette.Surface
    $Controls.RootBorder.BorderBrush = ConvertTo-MonitorThemeBrush $palette.Separator
    $Controls.TitleText.Foreground = ConvertTo-MonitorThemeBrush $palette.TextPrimary
    $Controls.FreshnessText.Foreground = ConvertTo-MonitorThemeBrush $palette.TextSecondary
    $Controls.ConnectionDot.Background = ConvertTo-MonitorThemeBrush $palette.TextSecondary
    foreach ($name in @(
        'PinButton', 'ThemeButton', 'ModeButton', 'LayoutButton', 'RefreshButton', 'HideButton', 'CloseButton',
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
            Initialize-MonitorNativeLibrary
        }
        return [CodexQuotaMonitor.Theme.NativeMethods]::EnableBlur($WindowHandle)
    }
    catch {
        return $false
    }
}

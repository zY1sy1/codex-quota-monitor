function Get-MonitorAppIconPath {
    [CmdletBinding()]
    param()

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $programRoot = Split-Path -Parent $moduleRoot
    foreach ($candidate in @(
        (Join-Path $programRoot 'assets\CodexQuotaMonitor.ico'),
        (Join-Path $programRoot 'assets\codex-quota-monitor-white-blue.ico'),
        (Join-Path $programRoot 'assets\codex-quota-monitor-white.ico')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function ConvertTo-MonitorWindowIconSource {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    try {
        $icon = [System.Drawing.Icon]::new([IO.Path]::GetFullPath($Path), 256, 256)
        try {
            return [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $icon.Handle,
                [Windows.Int32Rect]::Empty,
                [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
        }
        finally {
            $icon.Dispose()
        }
    }
    catch {
        return $null
    }
}

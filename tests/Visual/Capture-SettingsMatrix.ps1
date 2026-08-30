[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\outputs\visual\settings')
)

if (-not $IsWindows) {
    throw 'The settings visual matrix requires Windows.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne
    [Threading.ApartmentState]::STA) {
    throw 'The settings visual matrix requires an STA thread.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$companionRoot = Join-Path $PSScriptRoot '..\..\companion'
. (Join-Path $companionRoot 'Private\Theme.ps1')
. (Join-Path $companionRoot 'Private\SettingsView.ps1')
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Save-SettingsMatrixVisual {
    param(
        [Parameter(Mandatory)][Windows.Window]$Window,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Scale,
        [AllowNull()][object]$FocusControl = $null
    )

    $Window.WindowState = [Windows.WindowState]::Normal
    $Window.ShowInTaskbar = $false
    $Window.Show()
    $Window.UpdateLayout()
    if ($null -ne $FocusControl) {
        $null = $FocusControl.Focus()
    }
    $content = $Window.Content
    $logicalWidth = [Math]::Max(1, $content.ActualWidth)
    $logicalHeight = [Math]::Max(1, $content.ActualHeight)
    $content.Measure([Windows.Size]::new($logicalWidth, $logicalHeight))
    $content.Arrange([Windows.Rect]::new(0, 0, $logicalWidth, $logicalHeight))
    $content.UpdateLayout()

    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int][Math]::Ceiling($logicalWidth * $Scale),
        [int][Math]::Ceiling($logicalHeight * $Scale),
        96 * $Scale, 96 * $Scale,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.FileStream]::new(
        $Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read
    )
    try { $encoder.Save($stream) }
    finally {
        $stream.Dispose()
        $Window.Hide()
    }
}

$captured = [Collections.Generic.List[string]]::new()
foreach ($theme in @('Light', 'Dark')) {
    $view = New-SettingsView
    try {
        foreach ($scale in @(1.0, 1.5)) {
            $dpi = if ($scale -eq 1.0) { '100' } else { '150' }
            foreach ($case in @(
                @{ Page = 'Appearance'; Mode = 'Full'; Name = 'appearance-full' }
                @{ Page = 'Appearance'; Mode = 'CompactBar'; Name = 'appearance-disabled' }
                @{ Page = 'Behavior'; Mode = 'Full'; Name = 'behavior' }
                @{ Page = 'Relay'; Mode = 'Full'; Name = 'relay' }
            )) {
                & $view.SetSnapshot -Mode $case.Mode -Theme $theme -FullLayout Tabs `
                    -Topmost $true -Startup $false
                & $view.SetPage $case.Page
                $path = Join-Path $OutputDirectory (
                    '{0}-{1}-{2}.png' -f $theme.ToLowerInvariant(), $dpi, $case.Name
                )
                Save-SettingsMatrixVisual -Window $view.Window -Path $path -Scale $scale
                $captured.Add($path)
            }
        }

        & $view.SetSnapshot -Mode Full -Theme $theme -FullLayout Overview `
            -Topmost $false -Startup $true
        & $view.SetPage 'Behavior'
        & $view.SetStatus '无法应用主题：视觉测试错误' 'Error'
        $errorPath = Join-Path $OutputDirectory (
            '{0}-100-behavior-error.png' -f $theme.ToLowerInvariant()
        )
        Save-SettingsMatrixVisual -Window $view.Window -Path $errorPath -Scale 1.0 `
            -FocusControl $view.Controls.RefreshButton
        $captured.Add($errorPath)
    }
    finally {
        & $view.Dispose
    }
}

if ($captured.Count -ne 18) {
    throw "Expected 18 settings captures, created $($captured.Count)."
}
Write-Output (
    'Captured {0} deterministic settings images under {1}' -f
        $captured.Count, $OutputDirectory
)

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\outputs\visual')
)

if (-not $IsWindows) {
    throw 'The quota monitor visual matrix requires Windows.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The quota monitor visual matrix requires an STA thread.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$companionRoot = Join-Path $PSScriptRoot '..\..\companion'
foreach ($privateFile in @(
    'Theme.ps1', 'Settings.ps1', 'WpfView.ps1', 'CompactBarView.ps1', 'QuotaOrbView.ps1'
)) {
    . (Join-Path $companionRoot "Private\$privateFile")
}

[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function New-MatrixRow {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$SourceKind,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$GroupLabel,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ValueText,
        [Parameter(Mandatory)][double]$ProgressValue,
        [Parameter(Mandatory)][string]$Countdown,
        [Parameter(Mandatory)][string]$ResetTime,
        [string]$Unit = 'USD'
    )

    [pscustomobject][ordered]@{
        Key = $Key
        SourceKind = $SourceKind
        SourceId = $SourceId
        GroupLabel = $GroupLabel
        Label = $Label
        RemainingText = $ValueText
        ValueText = $ValueText
        SecondaryText = "单位：$Unit"
        ProgressValue = $ProgressValue
        CountdownText = $Countdown
        Countdown = $Countdown
        ResetTimeText = $ResetTime
        ResetTime = $ResetTime
        IsStale = $false
        UpdatedAt = [DateTimeOffset]'2026-08-03T12:00:00Z'
        State = 'Live'
        Unit = $Unit
        PlanName = $Label
    }
}

$officialRows = @(
    New-MatrixRow -Key 'official:five-hour' -SourceKind Official -SourceId codex `
        -GroupLabel 'Codex 官方额度' -Label '5 小时额度' -ValueText '74%' `
        -ProgressValue 74 -Countdown '04:59:59' -ResetTime '重置时间：今天 18:00'
    New-MatrixRow -Key 'official:weekly' -SourceKind Official -SourceId codex `
        -GroupLabel 'Codex 官方额度' -Label '每周额度' -ValueText '41%' `
        -ProgressValue 41 -Countdown '2 天 04:12:00' -ResetTime '重置时间：周五 09:30'
)
$relayRows = @(
    New-MatrixRow -Key 'relay:wallet' -SourceKind Relay -SourceId fixture `
        -GroupLabel '中转站额度' -Label 'Fixture Relay' -ValueText '¥18.42 / ¥100' `
        -ProgressValue 82 -Countdown '—' -ResetTime '更新时间：12:00' -Unit 'CNY'
)
$rows = @($officialRows + $relayRows)
$pinnedKey = 'official:five-hour'
$focusRow = $officialRows[0]

function Save-QuotaMatrixVisual {
    param(
        [Parameter(Mandatory)][Windows.Window]$Window,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Scale
    )

    $Window.WindowState = [Windows.WindowState]::Normal
    $Window.ShowInTaskbar = $false
    $Window.Show()
    $Window.UpdateLayout()
    $content = $Window.Content
    $content.Measure([Windows.Size]::new(2000, 1600))
    $desired = $content.DesiredSize
    $logicalWidth = [Math]::Max($Window.ActualWidth, $desired.Width)
    $logicalHeight = [Math]::Max($Window.ActualHeight, $desired.Height)
    $width = [Math]::Max(1, [int][Math]::Ceiling($logicalWidth * $Scale))
    $height = [Math]::Max(1, [int][Math]::Ceiling($logicalHeight * $Scale))
    $content.Arrange([Windows.Rect]::new(0, 0, $logicalWidth, $logicalHeight))
    $content.UpdateLayout()

    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width, $height, 96 * $Scale, 96 * $Scale,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $encoder.Save($stream) }
    finally {
        $stream.Dispose()
        $Window.Hide()
        $Window.Close()
    }
}

function New-MatrixViews {
    param([Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme)
    $full = New-QuotaWindowView -Theme $Theme -FullLayout Overview
    $compact = New-CompactBarView -Theme $Theme
    $orb = New-QuotaOrbView -Theme $Theme
    & $full.RenderGroups -OfficialRows $officialRows -RelayRows $relayRows -State $null -FocusKey $pinnedKey
    & $compact.RenderFocus -Row $focusRow
    & $orb.RenderFocus -Row $focusRow -PinnedKey $pinnedKey
    return [pscustomobject][ordered]@{ Full = $full; Compact = $compact; Orb = $orb }
}

$captured = [Collections.Generic.List[string]]::new()
foreach ($theme in @('Light', 'Dark')) {
    foreach ($scale in @(1.0, 1.5)) {
        $dpiLabel = if ($scale -eq 1.0) { '100' } else { '150' }
        $views = New-MatrixViews -Theme $theme
        try {
            foreach ($layout in @('Overview', 'Tabs')) {
                & $views.Full.SetLayout $layout
                $name = "{0}-{1}-full-{2}.png" -f $theme.ToLowerInvariant(), $dpiLabel, $layout.ToLowerInvariant()
                $path = Join-Path $OutputDirectory $name
                Save-QuotaMatrixVisual -Window $views.Full.Window -Path $path -Scale $scale
                $captured.Add($path)
            }
            $name = "{0}-{1}-compact-bar.png" -f $theme.ToLowerInvariant(), $dpiLabel
            $path = Join-Path $OutputDirectory $name
            Save-QuotaMatrixVisual -Window $views.Compact.Window -Path $path -Scale $scale
            $captured.Add($path)

            $name = "{0}-{1}-orb.png" -f $theme.ToLowerInvariant(), $dpiLabel
            $path = Join-Path $OutputDirectory $name
            Save-QuotaMatrixVisual -Window $views.Orb.Window -Path $path -Scale $scale
            $captured.Add($path)
        }
        finally {
            foreach ($view in @($views.Full, $views.Compact, $views.Orb)) {
                try { & $view.Dispose } catch {}
            }
        }
    }
}

if ($captured.Count -ne 16) {
    throw "Expected 16 visual captures, created $($captured.Count)."
}
Write-Output ("Captured {0} deterministic quota-monitor images under {1}" -f $captured.Count, $OutputDirectory)

if (-not (Get-Command -Name Get-MonitorThemePalette -CommandType Function -ErrorAction SilentlyContinue) -or
    -not (Get-Command -Name Enable-MonitorWindowBlur -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}

function Get-CompactPresentationField {
    param(
        [AllowNull()][object]$Row,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Row) { return $null }
    if ($Row -is [Collections.IDictionary]) {
        if (([Collections.IDictionary]$Row).Contains($Name)) {
            return ([Collections.IDictionary]$Row)[$Name]
        }
        return $null
    }
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CompactPresentationText {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-CompactPresentationField -Row $Row -Name $name
        if ($null -ne $value) { return [string]$value }
    }
    return ''
}

function ConvertTo-CompactProgressValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value.GetType().IsEnum) {
        return $null
    }
    if ([Type]::GetTypeCode($Value.GetType()) -notin @(
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
    )) {
        return $null
    }
    try {
        $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
            $number -lt 0 -or $number -gt 100) {
            return $null
        }
        return [double]$number
    }
    catch {
        return $null
    }
}

function ConvertTo-CompactBrush {
    param([Parameter(Mandatory)][string]$Color)
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-CompactBarThemeVisuals {
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][Collections.IDictionary]$Controls,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme
    )

    $palette = Get-MonitorThemePalette -Theme $Theme
    $Controls.RootBorder.Background = ConvertTo-CompactBrush $palette.Surface
    $Controls.RootBorder.BorderBrush = ConvertTo-CompactBrush $palette.Separator
    $Controls.MetricLabel.Foreground = ConvertTo-CompactBrush $palette.TextSecondary
    $Controls.MetricValue.Foreground = ConvertTo-CompactBrush $palette.TextPrimary
    $Controls.CountdownText.Foreground = ConvertTo-CompactBrush $palette.Accent
    $Controls.ResetTimeText.Foreground = ConvertTo-CompactBrush $palette.TextSecondary
    $Controls.ProgressTrack.Background = ConvertTo-CompactBrush $palette.Track
    $Controls.ProgressFill.Background = ConvertTo-CompactBrush $palette.Accent
    foreach ($name in @('ModeButton', 'CloseButton')) {
        $Controls[$name].Foreground = ConvertTo-CompactBrush $palette.TextPrimary
        $Controls[$name].Background = [Windows.Media.Brushes]::Transparent
        $Controls[$name].BorderBrush = [Windows.Media.Brushes]::Transparent
    }
    $Window.Tag = $Theme
    return $palette
}

function Get-CompactBarPlacement {
    param([Parameter(Mandatory)][Windows.Window]$Window)
    return [pscustomobject][ordered]@{
        Left = [double]$Window.Left
        Top = [double]$Window.Top
        Topmost = [bool]$Window.Topmost
        Visible = [bool]$Window.IsVisible
    }
}

function Test-CompactEventFromButton {
    param(
        [AllowNull()][object]$OriginalSource,
        [Parameter(Mandatory)][Windows.DependencyObject]$Root
    )

    $current = $OriginalSource
    while ($null -ne $current -and $current -is [Windows.DependencyObject]) {
        if ($current -is [Windows.Controls.Button]) { return $true }
        if ([object]::ReferenceEquals($current, $Root)) { break }
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) }
        catch { break }
    }
    return $false
}

function New-CompactBarView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\CompactBar.xaml'),
        [Parameter()][ValidateSet('Light', 'Dark')][string]$Theme = 'Dark',
        [Parameter()][AllowNull()][scriptblock]$OnDrag,
        [Parameter()][AllowNull()][scriptblock]$OnOpenFull,
        [Parameter()][AllowNull()][scriptblock]$OnModeRequested,
        [Parameter()][AllowNull()][scriptblock]$OnCloseRequested,
        [Parameter()][AllowNull()][scriptblock]$DragAction
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota compact bar requires an STA thread.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "Codex quota compact-bar XAML was not found: $XamlPath"
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            [IO.Path]::GetFullPath($XamlPath),
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.CloseInput = $false
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($window -isnot [Windows.Window]) {
        throw 'The Codex quota compact-bar XAML root must be a Window.'
    }

    $controls = [ordered]@{}
    foreach ($name in @(
        'RootBorder', 'HeaderDragArea', 'MetricLabel', 'MetricValue',
        'ProgressTrack', 'ProgressFill', 'CountdownText', 'ResetTimeText',
        'ModeButton', 'CloseButton'
    )) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            $window.Close()
            throw "The Codex quota compact-bar XAML is missing named control '$name'."
        }
        $controls[$name] = $control
    }

    if ($null -eq $DragAction) {
        $DragAction = {
            param([Windows.Window]$TargetWindow)
            $TargetWindow.DragMove()
        }
    }

    $state = [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        Theme = $Theme
        Palette = $null
        FocusRow = $null
        ProgressValue = $null
        AllowExit = $false
        Disposed = $false
        SuppressNextOpen = $false
        Callbacks = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnOpenFull = $OnOpenFull
            OnModeRequested = $OnModeRequested
            OnCloseRequested = $OnCloseRequested
        }
        DragAction = $DragAction
        CreateBrush = ${function:ConvertTo-CompactBrush}
        GetPresentationField = ${function:Get-CompactPresentationField}
        GetPresentationText = ${function:Get-CompactPresentationText}
        ConvertProgress = ${function:ConvertTo-CompactProgressValue}
        GetPlacementModel = ${function:Get-CompactBarPlacement}
        TestEventFromButton = ${function:Test-CompactEventFromButton}
        ApplyTheme = ${function:Set-CompactBarThemeVisuals}
        EnableBlur = ${function:Enable-MonitorWindowBlur}
        Delegates = [ordered]@{}
    }
    $state.Palette = & $state.ApplyTheme -Window $window -Controls $controls -Theme $Theme

    $invokeCallback = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return }
        $property = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) {
            & $property.Value @Arguments
        }
    }.GetNewClosure()

    $updateProgress = {
        if ($state.Disposed -or $null -eq $state.ProgressValue -or
            $state.Controls.ProgressTrack.Visibility -ne [Windows.Visibility]::Visible) {
            if ($null -ne $state.Controls) { $state.Controls.ProgressFill.Width = 0 }
            return
        }
        $trackWidth = [double]$state.Controls.ProgressTrack.ActualWidth
        if ([double]::IsNaN($trackWidth) -or [double]::IsInfinity($trackWidth) -or $trackWidth -lt 0) {
            $trackWidth = 0
        }
        $state.Controls.ProgressFill.Width = $trackWidth * $state.ProgressValue / 100.0
    }.GetNewClosure()

    $sizeChangedScript = {
        param($sender, $eventArgs)
        & $updateProgress
    }.GetNewClosure()
    $state.Delegates.TrackSizeChanged = [Windows.SizeChangedEventHandler]$sizeChangedScript

    $bodyUpScript = {
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        if ($state.SuppressNextOpen) {
            $state.SuppressNextOpen = $false
            return
        }
        if (& $state.TestEventFromButton -OriginalSource $eventArgs.OriginalSource -Root $state.Controls.RootBorder) {
            return
        }
        & $invokeCallback 'OnOpenFull' @()
    }.GetNewClosure()
    $state.Delegates.BodyMouseLeftButtonUp = [Windows.Input.MouseButtonEventHandler]$bodyUpScript

    $headerDownScript = {
        param($sender, $eventArgs)
        if ($state.Disposed -or $eventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left) { return }
        $state.SuppressNextOpen = $true
        & $state.DragAction $state.Window
        $placement = & $state.GetPlacementModel -Window $state.Window
        & $invokeCallback 'OnDrag' @($placement)
    }.GetNewClosure()
    $state.Delegates.HeaderMouseLeftButtonDown = [Windows.Input.MouseButtonEventHandler]$headerDownScript

    foreach ($definition in @(
        @{ Name = 'ModeClick'; Callback = 'OnModeRequested' },
        @{ Name = 'CloseClick'; Callback = 'OnCloseRequested' }
    )) {
        $callbackName = $definition.Callback
        $handlerScript = {
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            & $invokeCallback $callbackName @()
        }.GetNewClosure()
        $state.Delegates[$definition.Name] = [Windows.RoutedEventHandler]$handlerScript
    }

    $closingScript = {
        param($sender, [ComponentModel.CancelEventArgs]$eventArgs)
        if ($state.AllowExit -or $state.Disposed) { return }
        $eventArgs.Cancel = $true
        & $invokeCallback 'OnCloseRequested' @()
    }.GetNewClosure()
    $state.Delegates.Closing = [ComponentModel.CancelEventHandler]$closingScript

    $sourceInitializedScript = {
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        try {
            $handle = [Windows.Interop.WindowInteropHelper]::new($state.Window).Handle
            $null = & $state.EnableBlur -WindowHandle $handle
        }
        catch {}
    }.GetNewClosure()
    $state.Delegates.SourceInitialized = [EventHandler]$sourceInitializedScript

    $controls.ProgressTrack.Add_SizeChanged($state.Delegates.TrackSizeChanged)
    $controls.RootBorder.Add_MouseLeftButtonUp($state.Delegates.BodyMouseLeftButtonUp)
    $controls.HeaderDragArea.Add_MouseLeftButtonDown($state.Delegates.HeaderMouseLeftButtonDown)
    $controls.ModeButton.Add_Click($state.Delegates.ModeClick)
    $controls.CloseButton.Add_Click($state.Delegates.CloseClick)
    $window.Add_Closing($state.Delegates.Closing)
    $window.Add_SourceInitialized($state.Delegates.SourceInitialized)

    $renderFocus = {
        param([Parameter(Position = 0)][AllowNull()][object]$Row)
        if ($state.Disposed) { return }
        $state.FocusRow = $Row
        if ($null -eq $Row) {
            $state.Controls.MetricLabel.Text = '暂无可比较额度'
            $state.Controls.MetricValue.Text = '—'
            $state.Controls.CountdownText.Text = ''
            $state.Controls.ResetTimeText.Text = ''
            $state.ProgressValue = $null
            $state.Controls.ProgressTrack.Visibility = [Windows.Visibility]::Collapsed
            & $updateProgress
            return
        }

        $state.Controls.MetricLabel.Text = & $state.GetPresentationText $Row @('Label')
        $state.Controls.MetricValue.Text = & $state.GetPresentationText $Row @('ValueText', 'RemainingText')
        $state.Controls.CountdownText.Text = & $state.GetPresentationText $Row @('Countdown', 'CountdownText')
        $state.Controls.ResetTimeText.Text = & $state.GetPresentationText $Row @('ResetTime', 'ResetTimeText')
        $state.ProgressValue = & $state.ConvertProgress (
            & $state.GetPresentationField -Row $Row -Name 'ProgressValue'
        )
        if ($null -eq $state.ProgressValue) {
            $state.Controls.ProgressTrack.Visibility = [Windows.Visibility]::Collapsed
        }
        else {
            $state.Controls.ProgressTrack.Visibility = [Windows.Visibility]::Visible
        }
        & $updateProgress
    }.GetNewClosure()

    $setTheme = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed) { return }
        $state.Theme = $Theme
        $state.Palette = & $state.ApplyTheme -Window $state.Window -Controls $state.Controls -Theme $Theme
        & $updateProgress
    }.GetNewClosure()

    $show = { if (-not $state.Disposed) { $state.Window.Show() } }.GetNewClosure()
    $hide = { if (-not $state.Disposed) { $state.Window.Hide() } }.GetNewClosure()
    $activate = {
        if ($state.Disposed) { return }
        if (-not $state.Window.IsVisible) { $state.Window.Show() }
        if ($state.Window.WindowState -eq [Windows.WindowState]::Minimized) {
            $state.Window.WindowState = [Windows.WindowState]::Normal
        }
        $state.Window.Activate() | Out-Null
    }.GetNewClosure()
    $setTopmost = {
        param([Parameter(Mandatory, Position = 0)][bool]$Topmost)
        if (-not $state.Disposed) { $state.Window.Topmost = $Topmost }
    }.GetNewClosure()
    $getPlacement = {
        if ($state.Disposed -or $null -eq $state.Window) { return $null }
        return & $state.GetPlacementModel -Window $state.Window
    }.GetNewClosure()
    $setCallbacks = {
        param(
            [Parameter()][AllowNull()][scriptblock]$OnDrag,
            [Parameter()][AllowNull()][scriptblock]$OnOpenFull,
            [Parameter()][AllowNull()][scriptblock]$OnModeRequested,
            [Parameter()][AllowNull()][scriptblock]$OnCloseRequested
        )
        if ($state.Disposed) { return }
        $state.Callbacks = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnOpenFull = $OnOpenFull
            OnModeRequested = $OnModeRequested
            OnCloseRequested = $OnCloseRequested
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        $state.AllowExit = $true
        $targetWindow = $state.Window
        $targetControls = $state.Controls
        $delegates = $state.Delegates

        if ($null -ne $targetControls -and $null -ne $delegates) {
            $targetControls.ProgressTrack.Remove_SizeChanged($delegates.TrackSizeChanged)
            $targetControls.RootBorder.Remove_MouseLeftButtonUp($delegates.BodyMouseLeftButtonUp)
            $targetControls.HeaderDragArea.Remove_MouseLeftButtonDown($delegates.HeaderMouseLeftButtonDown)
            $targetControls.ModeButton.Remove_Click($delegates.ModeClick)
            $targetControls.CloseButton.Remove_Click($delegates.CloseClick)
        }
        if ($null -ne $targetWindow -and $null -ne $delegates) {
            $targetWindow.Remove_Closing($delegates.Closing)
            $targetWindow.Remove_SourceInitialized($delegates.SourceInitialized)
        }
        $state.Callbacks = $null
        $state.DragAction = $null
        $state.CreateBrush = $null
        $state.GetPresentationField = $null
        $state.GetPresentationText = $null
        $state.ConvertProgress = $null
        $state.GetPlacementModel = $null
        $state.TestEventFromButton = $null
        $state.ApplyTheme = $null
        $state.EnableBlur = $null
        if ($null -ne $delegates) { $delegates.Clear() }
        if ($null -ne $targetWindow) {
            try { $targetWindow.Close() }
            catch [InvalidOperationException] {}
        }
        $state.Window = $null
        $state.Controls = $null
    }.GetNewClosure()

    & $renderFocus $null
    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        Show = $show
        Hide = $hide
        Activate = $activate
        RenderFocus = $renderFocus
        SetTheme = $setTheme
        SetTopmost = $setTopmost
        GetPlacement = $getPlacement
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}

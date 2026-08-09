if (-not (Get-Command -Name Get-MonitorThemePalette -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}

function Get-QuotaOrbArcGeometry {
    param(
        [ValidateRange(0, 100)][double]$Percent,
        [double]$Radius = 35
    )

    $angle = [Math]::Min(359.999, 360 * $Percent / 100)
    $radians = ($angle - 90) * [Math]::PI / 180
    [pscustomobject][ordered]@{
        EndX = $Radius + ($Radius * [Math]::Cos($radians))
        EndY = $Radius + ($Radius * [Math]::Sin($radians))
        IsLargeArc = $angle -gt 180
    }
}

function Get-QuotaOrbPresentationField {
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

function Get-QuotaOrbPresentationText {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-QuotaOrbPresentationField -Row $Row -Name $name
        if ($null -ne $value) { return [string]$value }
    }
    return ''
}

function ConvertTo-QuotaOrbProgressValue {
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

function ConvertTo-QuotaOrbBrush {
    param([Parameter(Mandatory)][string]$Color)
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-QuotaOrbThemeVisuals {
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][Collections.IDictionary]$Controls,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme
    )

    $palette = Get-MonitorThemePalette -Theme $Theme
    $Controls.RootBorder.Background = ConvertTo-QuotaOrbBrush $palette.Surface
    $Controls.RootBorder.BorderBrush = ConvertTo-QuotaOrbBrush $palette.Separator
    $Controls.RingTrack.Stroke = ConvertTo-QuotaOrbBrush $palette.Track
    $Controls.RingValue.Stroke = ConvertTo-QuotaOrbBrush $palette.Accent
    $Controls.MetricText.Foreground = ConvertTo-QuotaOrbBrush $palette.TextPrimary
    $Controls.ValueText.Foreground = ConvertTo-QuotaOrbBrush $palette.TextPrimary
    $Controls.SourceText.Foreground = ConvertTo-QuotaOrbBrush $palette.TextSecondary
    foreach ($name in @('ModeButton', 'CloseButton')) {
        $Controls[$name].Foreground = ConvertTo-QuotaOrbBrush $palette.TextPrimary
        $Controls[$name].Background = [Windows.Media.Brushes]::Transparent
        $Controls[$name].BorderBrush = [Windows.Media.Brushes]::Transparent
    }
    $Window.Tag = $Theme
    return $palette
}

function Get-QuotaOrbPlacement {
    param([Parameter(Mandatory)][Windows.Window]$Window)

    $left = [double]$Window.Left
    $top = [double]$Window.Top
    if ([double]::IsNaN($left) -or [double]::IsInfinity($left)) { $left = 0 }
    if ([double]::IsNaN($top) -or [double]::IsInfinity($top)) { $top = 0 }
    return [pscustomobject][ordered]@{
        Left = $left
        Top = $top
        Topmost = [bool]$Window.Topmost
        Visible = [bool]$Window.IsVisible
    }
}

function Test-QuotaOrbEventFromButton {
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

function New-QuotaOrbView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\QuotaOrb.xaml'),
        [Parameter()][ValidateSet('Light', 'Dark')][string]$Theme = 'Dark',
        [Parameter()][AllowNull()][scriptblock]$OnDrag,
        [Parameter()][AllowNull()][scriptblock]$OnOpenFull,
        [Parameter()][AllowNull()][scriptblock]$OnModeRequested,
        [Parameter()][AllowNull()][scriptblock]$OnCloseRequested,
        [Parameter()][AllowNull()][scriptblock]$DragAction
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota orb requires an STA thread.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "Codex quota orb XAML was not found: $XamlPath"
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
        throw 'The Codex quota orb XAML root must be a Window.'
    }

    $controls = [ordered]@{}
    foreach ($name in @(
        'RootBorder', 'HeaderDragArea', 'RingTrack', 'RingValue', 'MetricText',
        'ValueText', 'SourceText', 'ModeButton', 'CloseButton'
    )) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            $window.Close()
            throw "The Codex quota orb XAML is missing named control '$name'."
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
        GetPresentationField = ${function:Get-QuotaOrbPresentationField}
        GetPresentationText = ${function:Get-QuotaOrbPresentationText}
        ConvertProgress = ${function:ConvertTo-QuotaOrbProgressValue}
        GetArcGeometry = ${function:Get-QuotaOrbArcGeometry}
        GetPlacementModel = ${function:Get-QuotaOrbPlacement}
        TestEventFromButton = ${function:Test-QuotaOrbEventFromButton}
        ApplyTheme = ${function:Set-QuotaOrbThemeVisuals}
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

    $controls.RootBorder.Add_MouseLeftButtonUp($state.Delegates.BodyMouseLeftButtonUp)
    $controls.HeaderDragArea.Add_MouseLeftButtonDown($state.Delegates.HeaderMouseLeftButtonDown)
    $controls.ModeButton.Add_Click($state.Delegates.ModeClick)
    $controls.CloseButton.Add_Click($state.Delegates.CloseClick)
    $window.Add_Closing($state.Delegates.Closing)

    $renderFocus = {
        param(
            [Parameter(Position = 0)][AllowNull()][object]$Row,
            [Parameter()][AllowNull()][string]$PinnedKey
        )
        if ($state.Disposed) { return }
        $state.FocusRow = $Row
        $state.Controls.RingValue.Data = $null
        $state.Controls.RingValue.Visibility = [Windows.Visibility]::Collapsed
        $state.Controls.ValueText.Visibility = [Windows.Visibility]::Collapsed
        $state.Controls.MetricText.Visibility = [Windows.Visibility]::Visible

        if ($null -eq $Row) {
            $state.ProgressValue = $null
            $state.Controls.MetricText.Text = '—'
            $state.Controls.ValueText.Text = ''
            $state.Controls.SourceText.Text = ''
            $state.Controls.RootBorder.ToolTip = $null
            return
        }

        $label = & $state.GetPresentationText $Row @('Label')
        $valueText = & $state.GetPresentationText $Row @('ValueText', 'RemainingText')
        $state.Controls.SourceText.Text = $label
        $state.Controls.ValueText.Text = $valueText
        $state.ProgressValue = & $state.ConvertProgress (
            & $state.GetPresentationField -Row $Row -Name 'ProgressValue'
        )

        if ($null -ne $state.ProgressValue) {
            $state.Controls.MetricText.Text = $valueText
            $arc = & $state.GetArcGeometry -Percent $state.ProgressValue -Radius 35
            $figure = [Windows.Media.PathFigure]::new()
            $figure.StartPoint = [Windows.Point]::new(35, 0)
            $figure.IsClosed = $false
            $figure.IsFilled = $false
            $segment = [Windows.Media.ArcSegment]::new()
            $segment.Point = [Windows.Point]::new($arc.EndX, $arc.EndY)
            $segment.Size = [Windows.Size]::new(35, 35)
            $segment.IsLargeArc = [bool]$arc.IsLargeArc
            $segment.SweepDirection = [Windows.Media.SweepDirection]::Clockwise
            $figure.Segments.Add($segment)
            $pathGeometry = [Windows.Media.PathGeometry]::new()
            $pathGeometry.Figures.Add($figure)
            $state.Controls.RingValue.Data = $pathGeometry
            $state.Controls.RingValue.Visibility = [Windows.Visibility]::Visible
        }
        else {
            $rowKey = [string](& $state.GetPresentationField -Row $Row -Name 'Key')
            if (-not [string]::IsNullOrWhiteSpace($PinnedKey) -and $rowKey -ceq $PinnedKey) {
                $state.Controls.MetricText.Visibility = [Windows.Visibility]::Collapsed
                $state.Controls.ValueText.Visibility = [Windows.Visibility]::Visible
            }
            else {
                $state.Controls.MetricText.Text = '—'
            }
        }

        $groupLabel = & $state.GetPresentationText $Row @('GroupLabel')
        $isStale = [bool](& $state.GetPresentationField -Row $Row -Name 'IsStale')
        $freshness = if ($isStale) { '数据已过期' } else { '数据正常' }
        $resetTime = & $state.GetPresentationText $Row @('ResetTime', 'ResetTimeText')
        $state.Controls.RootBorder.ToolTip = "${groupLabel} ${label}`n${valueText}`n${freshness}`n${resetTime}"
    }.GetNewClosure()

    $setTheme = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed) { return }
        $state.Theme = $Theme
        $state.Palette = & $state.ApplyTheme -Window $state.Window -Controls $state.Controls -Theme $Theme
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
            $targetControls.RootBorder.Remove_MouseLeftButtonUp($delegates.BodyMouseLeftButtonUp)
            $targetControls.HeaderDragArea.Remove_MouseLeftButtonDown($delegates.HeaderMouseLeftButtonDown)
            $targetControls.ModeButton.Remove_Click($delegates.ModeClick)
            $targetControls.CloseButton.Remove_Click($delegates.CloseClick)
        }
        if ($null -ne $targetWindow -and $null -ne $delegates) {
            $targetWindow.Remove_Closing($delegates.Closing)
        }
        $state.Callbacks = $null
        $state.DragAction = $null
        $state.GetPresentationField = $null
        $state.GetPresentationText = $null
        $state.ConvertProgress = $null
        $state.GetArcGeometry = $null
        $state.GetPlacementModel = $null
        $state.TestEventFromButton = $null
        $state.ApplyTheme = $null
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

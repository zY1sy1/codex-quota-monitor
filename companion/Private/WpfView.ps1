if (-not (Get-Command -Name Get-MonitorThemePalette -CommandType Function -ErrorAction SilentlyContinue) -or
    -not (Get-Command -Name Set-MonitorWindowTheme -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}
if (-not (Get-Command -Name ConvertTo-QuotaDisplayValueText -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Presentation.ps1')
}

function Get-WpfPresentationField {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$PresentationRow,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $PresentationRow) {
        return $null
    }
    if ($PresentationRow -is [Collections.IDictionary]) {
        if (([Collections.IDictionary]$PresentationRow).Contains($Name)) {
            return ([Collections.IDictionary]$PresentationRow)[$Name]
        }
        return $null
    }

    $property = $PresentationRow.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-WpfProgressValue {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

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
        [double]$progress = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($progress) -or [double]::IsInfinity($progress) -or
            $progress -lt 0.0 -or $progress -gt 100.0) {
            return $null
        }
        return $progress
    }
    catch {
        return $null
    }
}

function ConvertTo-WpfBrush {
    param([Parameter(Mandatory)][string]$Color)
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function New-WpfQuotaCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$PresentationRow,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Palette,

        [Parameter(Mandatory)]
        [Windows.Style]$FocusButtonStyle,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnFocusRequested,

        [Parameter()]
        [AllowNull()]
        [string]$SelectedKey
    )

    $key = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'Key')
    $isRelay = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'SourceKind') -eq 'Relay'
    $selected = -not [string]::IsNullOrEmpty($SelectedKey) -and $SelectedKey -eq $key
    $brush = { param([string]$Color) [Windows.Media.BrushConverter]::new().ConvertFromString($Color) }

    $card = [Windows.Controls.Border]::new()
    $card.Background = & $brush $(if ($selected) { $Palette.SelectionSurface } else { $Palette.SurfaceStrong })
    $card.BorderBrush = & $brush $(if ($selected) { $Palette.Accent } else { $Palette.Separator })
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(8)
    $card.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $card.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
    $card.Tag = $key

    $grid = [Windows.Controls.Grid]::new()
    foreach ($nullValue in 1..4) {
        $definition = [Windows.Controls.RowDefinition]::new()
        $definition.Height = [Windows.GridLength]::Auto
        $grid.RowDefinitions.Add($definition)
    }

    $heading = [Windows.Controls.Grid]::new()
    $labelColumn = [Windows.Controls.ColumnDefinition]::new()
    $labelColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $heading.ColumnDefinitions.Add($labelColumn)
    foreach ($nullValue in 1..2) {
        $column = [Windows.Controls.ColumnDefinition]::new()
        $column.Width = [Windows.GridLength]::Auto
        $heading.ColumnDefinitions.Add($column)
    }

    $inUse = [bool](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'InUse')

    $headingText = [Windows.Controls.StackPanel]::new()
    $headingText.Orientation = [Windows.Controls.Orientation]::Horizontal
    $headingText.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $headingText.IsHitTestVisible = $false

    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = [string](Get-WpfPresentationField $PresentationRow 'Label')
    $label.Foreground = & $brush $Palette.TextPrimary
    $label.FontSize = 12
    $label.FontWeight = [Windows.FontWeights]::SemiBold
    $label.TextWrapping = [Windows.TextWrapping]::Wrap
    $label.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $label.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $label.Tag = 'QuotaLabel'
    [Windows.Automation.AutomationProperties]::SetName($label, "额度名称：$($label.Text)")

    $dotColor = if ($null -ne $Palette.PSObject.Properties['Success']) { $Palette.Success } else { $Palette.Accent }
    $inUseDot = [Windows.Shapes.Ellipse]::new()
    $inUseDot.Width = 8
    $inUseDot.Height = 8
    $inUseDot.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $inUseDot.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $inUseDot.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $inUseDot.Fill = & $brush $dotColor
    $inUseDot.Tag = 'QuotaInUseDot'
    $inUseDot.Visibility = $(if ($inUse) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
    [Windows.Automation.AutomationProperties]::SetName($inUseDot, '正在使用')

    $headingText.Children.Add($inUseDot) | Out-Null
    $headingText.Children.Add($label) | Out-Null
    [Windows.Controls.Grid]::SetColumn($headingText, 0)
    $heading.Children.Add($headingText) | Out-Null
    $card.Resources['InUseDot'] = $inUseDot

    $remainingText = Get-WpfPresentationField $PresentationRow 'ValueText'
    if ($null -eq $remainingText) {
        $remainingText = Get-WpfPresentationField $PresentationRow 'RemainingText'
    }
    $remaining = [Windows.Controls.TextBlock]::new()
    $remaining.Text = ConvertTo-QuotaDisplayValueText ([string]$remainingText)
    $remaining.Foreground = & $brush $Palette.TextPrimary
    $remaining.FontSize = 24
    $remaining.FontWeight = [Windows.FontWeights]::Bold
    $remaining.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $remaining.Tag = 'QuotaRemaining'
    [Windows.Automation.AutomationProperties]::SetName($remaining, "剩余额度：$($remaining.Text)")
    [Windows.Controls.Grid]::SetColumn($remaining, 1)
    $heading.Children.Add($remaining) | Out-Null

    $focusButton = [Windows.Controls.Button]::new()
    $focusButton.Style = $FocusButtonStyle
    $focusButton.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
    $focusButton.Foreground = & $brush $(if ($selected) { $Palette.Accent } else { $Palette.TextSecondary })
    $focusButton.Background = $(
        if ($selected) { & $brush $Palette.AccentSoft }
        else { [Windows.Media.Brushes]::Transparent }
    )
    $focusButton.Tag = 'QuotaFocus'
    $focusButton.ToolTip = $(if ($selected) { '取消迷你模式固定显示' } else { '设为迷你模式显示项' })

    $focusVisual = [Windows.Controls.Grid]::new()
    $focusVisual.Width = 16
    $focusVisual.Height = 16
    $focusVisual.IsHitTestVisible = $false

    $focusRing = [Windows.Shapes.Ellipse]::new()
    $focusRing.Width = 16
    $focusRing.Height = 16
    $focusRing.StrokeThickness = 1.5
    $focusRing.Tag = 'QuotaFocusRing'

    $focusDot = [Windows.Shapes.Ellipse]::new()
    $focusDot.Width = 6
    $focusDot.Height = 6
    $focusDot.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $focusDot.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $focusDot.Visibility = $(
        if ($selected) { [Windows.Visibility]::Visible }
        else { [Windows.Visibility]::Collapsed }
    )
    $focusDot.Tag = 'QuotaFocusDot'

    $ringBinding = [Windows.Data.Binding]::new('Foreground')
    $ringBinding.RelativeSource = [Windows.Data.RelativeSource]::new(
        [Windows.Data.RelativeSourceMode]::FindAncestor,
        [Windows.Controls.Button],
        1
    )
    [Windows.Data.BindingOperations]::SetBinding(
        $focusRing,
        [Windows.Shapes.Shape]::StrokeProperty,
        $ringBinding
    ) | Out-Null

    $dotBinding = [Windows.Data.Binding]::new('Foreground')
    $dotBinding.RelativeSource = [Windows.Data.RelativeSource]::new(
        [Windows.Data.RelativeSourceMode]::FindAncestor,
        [Windows.Controls.Button],
        1
    )
    [Windows.Data.BindingOperations]::SetBinding(
        $focusDot,
        [Windows.Shapes.Shape]::FillProperty,
        $dotBinding
    ) | Out-Null

    $focusVisual.Children.Add($focusRing) | Out-Null
    $focusVisual.Children.Add($focusDot) | Out-Null
    $focusButton.Content = $focusVisual
    [Windows.Automation.AutomationProperties]::SetName($focusButton, [string]$focusButton.ToolTip)
    [Windows.Controls.Grid]::SetColumn($focusButton, 2)

    $focusHandlerScript = {
        param($sender, $eventArgs)
        if ($null -ne $OnFocusRequested) {
            & $OnFocusRequested $key
        }
    }.GetNewClosure()
    $focusHandler = [Windows.RoutedEventHandler]$focusHandlerScript
    $focusButton.Add_Click($focusHandler)
    $focusButton.CommandParameter = $focusHandler
    $heading.Children.Add($focusButton) | Out-Null
    $card.Resources['FocusButton'] = $focusButton
    $card.Resources['FocusHandler'] = $focusHandler

    [Windows.Controls.Grid]::SetRow($heading, 0)
    $grid.Children.Add($heading) | Out-Null

    $progressBar = [Windows.Controls.ProgressBar]::new()
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Height = 6
    $progressBar.Margin = [Windows.Thickness]::new(0, 7, 0, 7)
    $progressBar.Background = & $brush $Palette.Track
    $progressBar.Foreground = & $brush $Palette.Accent
    $progressBar.Tag = 'QuotaProgress'
    [Windows.Automation.AutomationProperties]::SetName($progressBar, '剩余额度进度')
    $progressValue = ConvertTo-WpfProgressValue (Get-WpfPresentationField $PresentationRow 'ProgressValue')
    if ($null -eq $progressValue) {
        $progressBar.Visibility = [Windows.Visibility]::Collapsed
    }
    else {
        $progressBar.Value = $progressValue
        $progressBar.Visibility = [Windows.Visibility]::Visible
    }
    [Windows.Controls.Grid]::SetRow($progressBar, 1)
    $grid.Children.Add($progressBar) | Out-Null

    $secondary = [Windows.Controls.TextBlock]::new()
    $secondary.Text = [string](Get-WpfPresentationField $PresentationRow 'SecondaryText')
    $secondary.Foreground = & $brush $Palette.TextSecondary
    $secondary.FontSize = 11
    $secondary.TextWrapping = [Windows.TextWrapping]::Wrap
    $secondary.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
    $secondary.Tag = 'QuotaSecondary'
    [Windows.Automation.AutomationProperties]::SetName($secondary, $secondary.Text)
    if ([string]::IsNullOrWhiteSpace($secondary.Text)) {
        $secondary.Visibility = [Windows.Visibility]::Collapsed
    }
    [Windows.Controls.Grid]::SetRow($secondary, 2)
    $grid.Children.Add($secondary) | Out-Null

    $timing = [Windows.Controls.Grid]::new()
    $countdownColumn = [Windows.Controls.ColumnDefinition]::new()
    $countdownColumn.Width = [Windows.GridLength]::Auto
    $timing.ColumnDefinitions.Add($countdownColumn)
    $resetColumn = [Windows.Controls.ColumnDefinition]::new()
    $resetColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $timing.ColumnDefinitions.Add($resetColumn)

    $countdownText = Get-WpfPresentationField $PresentationRow 'Countdown'
    if ($null -eq $countdownText) {
        $countdownText = Get-WpfPresentationField $PresentationRow 'CountdownText'
    }
    $countdown = [Windows.Controls.TextBlock]::new()
    $countdown.Text = [string]$countdownText
    $countdown.Foreground = & $brush $Palette.Accent
    $countdown.FontSize = 11
    $countdown.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $countdown.Tag = 'QuotaCountdown'
    [Windows.Automation.AutomationProperties]::SetName($countdown, "重置倒计时：$($countdown.Text)")
    [Windows.Controls.Grid]::SetColumn($countdown, 0)
    $timing.Children.Add($countdown) | Out-Null

    $resetTimeText = Get-WpfPresentationField $PresentationRow 'ResetTime'
    if ($null -eq $resetTimeText) {
        $resetTimeText = Get-WpfPresentationField $PresentationRow 'ResetTimeText'
    }
    $resetTime = [Windows.Controls.TextBlock]::new()
    $resetTime.Text = [string]$resetTimeText
    $resetTime.Foreground = & $brush $Palette.TextSecondary
    $resetTime.FontSize = 10
    $resetTime.TextAlignment = [Windows.TextAlignment]::Right
    $resetTime.TextWrapping = [Windows.TextWrapping]::Wrap
    $resetTime.Tag = 'QuotaResetTime'
    [Windows.Automation.AutomationProperties]::SetName($resetTime, $resetTime.Text)
    [Windows.Controls.Grid]::SetColumn($resetTime, 1)
    $timing.Children.Add($resetTime) | Out-Null
    [Windows.Controls.Grid]::SetRow($timing, 3)
    $grid.Children.Add($timing) | Out-Null

    if ($isRelay) {
        foreach ($text in @($label, $remaining, $secondary, $countdown, $resetTime)) {
            $text.VerticalAlignment = [Windows.VerticalAlignment]::Center
        }
    }

    # Capture the live element references so an in-place update can re-color
    # and re-text the card without rebuilding the whole visual tree each tick.
    $card.Resources['Label'] = $label
    $card.Resources['Remaining'] = $remaining
    $card.Resources['Progress'] = $progressBar
    $card.Resources['Secondary'] = $secondary
    $card.Resources['Countdown'] = $countdown
    $card.Resources['ResetTime'] = $resetTime
    $card.Resources['FocusRing'] = $focusRing
    $card.Resources['FocusDot'] = $focusDot

    $card.Child = $grid
    return $card
}

function Get-WpfQuotaWindowPlacement {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][Windows.Window]$Window)

    return [pscustomobject][ordered]@{
        Left = [double]$Window.Left
        Top = [double]$Window.Top
        Topmost = [bool]$Window.Topmost
        Visible = [bool]$Window.IsVisible
    }
}

function New-QuotaWindowView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\MainWindow.xaml'),

        [Parameter()][ValidateSet('Light', 'Dark')][string]$Theme = 'Dark',
        [Parameter()][ValidateSet('Overview', 'Tabs')][string]$FullLayout = 'Overview',
        [Parameter()][AllowNull()][scriptblock]$OnDrag,
        [Parameter()][AllowNull()][scriptblock]$OnToggleTopmost,
        [Parameter()][AllowNull()][scriptblock]$OnHide,
        [Parameter()][AllowNull()][scriptblock]$OnCloseRequested,
        [Parameter()][AllowNull()][scriptblock]$OnThemeRequested,
        [Parameter()][AllowNull()][scriptblock]$OnModeRequested,
        [Parameter()][AllowNull()][scriptblock]$OnLayoutRequested,
        [Parameter()][AllowNull()][scriptblock]$OnFocusRequested,
        [Parameter()][AllowNull()][scriptblock]$OnRefreshRequested,
        [Parameter()][AllowNull()][scriptblock]$DragAction
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota floating window requires an STA thread.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "Codex quota floating-window XAML was not found: $XamlPath"
    }

    $resolvedXamlPath = [IO.Path]::GetFullPath($XamlPath)
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            $resolvedXamlPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read
        )
        $readerSettings = [Xml.XmlReaderSettings]::new()
        $readerSettings.CloseInput = $false
        $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $reader = [Xml.XmlReader]::Create($stream, $readerSettings)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    if ($window -isnot [Windows.Window]) {
        throw 'The Codex quota floating-window XAML root must be a Window.'
    }

    $controlNames = @(
        'RootBorder', 'HeaderDragArea', 'ConnectionDot', 'TitleText', 'PinButton',
        'ThemeButton', 'ModeButton', 'LayoutButton', 'RefreshButton', 'HideButton', 'CloseButton',
        'OverviewPanel', 'TabsPanel', 'OfficialRows', 'RelayRows',
        'OfficialTabRows', 'RelayTabRows', 'OfficialTabButton', 'RelayTabButton',
        'OfficialExpander', 'RelayExpander', 'FreshnessText'
    )
    $controls = [ordered]@{}
    try {
        foreach ($name in $controlNames) {
            $control = $window.FindName($name)
            if ($null -eq $control) {
                throw "The Codex quota floating-window XAML is missing named control '$name'."
            }
            $controls[$name] = $control
        }
    }
    catch {
        $window.Close()
        throw
    }

    $focusButtonStyle = $window.TryFindResource('QuotaFocusButton')
    if ($focusButtonStyle -isnot [Windows.Style]) {
        $window.Close()
        throw "The Codex quota floating-window XAML is missing style 'QuotaFocusButton'."
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
        AllowExit = $false
        Disposed = $false
        Theme = $Theme
        FullLayout = $FullLayout
        ActiveTab = 'Official'
        OfficialRows = [object[]]@()
        RelayRows = [object[]]@()
        FocusKey = $null
        ConnectionState = $null
        FreshnessIsLive = $null
        Palette = $null
        Callbacks = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnToggleTopmost = $OnToggleTopmost
            OnHide = $OnHide
            OnCloseRequested = $OnCloseRequested
            OnThemeRequested = $OnThemeRequested
            OnModeRequested = $OnModeRequested
            OnLayoutRequested = $OnLayoutRequested
            OnFocusRequested = $OnFocusRequested
            OnRefreshRequested = $OnRefreshRequested
        }
        DragAction = $DragAction
        CreateBrush = ${function:ConvertTo-WpfBrush}
        CreateQuotaCard = ${function:New-WpfQuotaCard}
        GetPresentationField = ${function:Get-WpfPresentationField}
        ConvertProgress = ${function:ConvertTo-WpfProgressValue}
        QuotaDisplayText = ${function:ConvertTo-QuotaDisplayValueText}
        FocusButtonStyle = $focusButtonStyle
        GetPlacementModel = ${function:Get-WpfQuotaWindowPlacement}
        ApplyTheme = ${function:Set-MonitorWindowTheme}
        Delegates = [ordered]@{}
    }

    $state.Palette = Set-MonitorWindowTheme -Window $window -Controls $controls -Theme $Theme

    $invokeCallback = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return }
        $callback = $state.Callbacks.PSObject.Properties[$Name].Value
        if ($null -ne $callback) {
            & $callback @Arguments
        }
    }.GetNewClosure()

    $mouseHandlerScript = {
        param($sender, $eventArgs)
        if ($state.Disposed -or $eventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left) { return }
        & $state.DragAction $state.Window
        $placement = & $state.GetPlacementModel -Window $state.Window
        & $invokeCallback 'OnDrag' @($placement)
    }.GetNewClosure()
    $state.Delegates.MouseLeftButtonDown = [Windows.Input.MouseButtonEventHandler]$mouseHandlerScript

    foreach ($definition in @(
        @{ Name = 'PinClick'; Callback = 'OnToggleTopmost' },
        @{ Name = 'ThemeClick'; Callback = 'OnThemeRequested' },
        @{ Name = 'ModeClick'; Callback = 'OnModeRequested' },
        @{ Name = 'LayoutClick'; Callback = 'OnLayoutRequested' },
        @{ Name = 'RefreshClick'; Callback = 'OnRefreshRequested' },
        @{ Name = 'HideClick'; Callback = 'OnHide' },
        @{ Name = 'CloseClick'; Callback = 'OnCloseRequested' }
    )) {
        $callbackName = $definition.Callback
        $handlerScript = {
            param($sender, $eventArgs)
            & $invokeCallback $callbackName @()
        }.GetNewClosure()
        $state.Delegates[$definition.Name] = [Windows.RoutedEventHandler]$handlerScript
    }

    $updateLayoutVisuals = {
        if ($state.Disposed) { return }
        $state.Controls.OverviewPanel.Visibility = $(
            if ($state.FullLayout -eq 'Overview') { [Windows.Visibility]::Visible }
            else { [Windows.Visibility]::Collapsed }
        )
        $state.Controls.TabsPanel.Visibility = $(
            if ($state.FullLayout -eq 'Tabs') { [Windows.Visibility]::Visible }
            else { [Windows.Visibility]::Collapsed }
        )
        $officialSelected = $state.ActiveTab -eq 'Official'
        $state.Controls.OfficialTabRows.Visibility = $(
            if ($officialSelected) { [Windows.Visibility]::Visible }
            else { [Windows.Visibility]::Collapsed }
        )
        $state.Controls.RelayTabRows.Visibility = $(
            if ($officialSelected) { [Windows.Visibility]::Collapsed }
            else { [Windows.Visibility]::Visible }
        )
        $state.Controls.OfficialTabButton.Background = $(
            if ($officialSelected) { & $state.CreateBrush $state.Palette.SurfaceStrong }
            else { [Windows.Media.Brushes]::Transparent }
        )
        $state.Controls.RelayTabButton.Background = $(
            if ($officialSelected) { [Windows.Media.Brushes]::Transparent }
            else { & $state.CreateBrush $state.Palette.SurfaceStrong }
        )
    }.GetNewClosure()

    $officialTabHandlerScript = {
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        $state.ActiveTab = 'Official'
        & $updateLayoutVisuals
    }.GetNewClosure()
    $state.Delegates.OfficialTabClick = [Windows.RoutedEventHandler]$officialTabHandlerScript
    $relayTabHandlerScript = {
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        $state.ActiveTab = 'Relay'
        & $updateLayoutVisuals
    }.GetNewClosure()
    $state.Delegates.RelayTabClick = [Windows.RoutedEventHandler]$relayTabHandlerScript

    $closingHandlerScript = {
        param($sender, [ComponentModel.CancelEventArgs]$eventArgs)
        if ($state.AllowExit -or $state.Disposed) { return }
        $eventArgs.Cancel = $true
        & $invokeCallback 'OnCloseRequested' @()
    }.GetNewClosure()
    $state.Delegates.Closing = [ComponentModel.CancelEventHandler]$closingHandlerScript

    $controls.HeaderDragArea.Add_MouseLeftButtonDown($state.Delegates.MouseLeftButtonDown)
    $controls.PinButton.Add_Click($state.Delegates.PinClick)
    $controls.ThemeButton.Add_Click($state.Delegates.ThemeClick)
    $controls.ModeButton.Add_Click($state.Delegates.ModeClick)
    $controls.LayoutButton.Add_Click($state.Delegates.LayoutClick)
    $controls.RefreshButton.Add_Click($state.Delegates.RefreshClick)
    $controls.HideButton.Add_Click($state.Delegates.HideClick)
    $controls.CloseButton.Add_Click($state.Delegates.CloseClick)
    $controls.OfficialTabButton.Add_Click($state.Delegates.OfficialTabClick)
    $controls.RelayTabButton.Add_Click($state.Delegates.RelayTabClick)
    $window.Add_Closing($state.Delegates.Closing)
    & $updateLayoutVisuals

    $focusRequest = {
        param([string]$Key)
        if ($state.Disposed) { return }
        & $invokeCallback 'OnFocusRequested' @($Key)
    }.GetNewClosure()

    $detachCardHandler = {
        param($Card)
        if ($null -eq $Card) { return }
        $button = $Card.Resources['FocusButton']
        $handler = $Card.Resources['FocusHandler']
        if ($null -ne $button -and $null -ne $handler) {
            try { $button.Remove_Click($handler) } catch { }
            $button.CommandParameter = $null
        }
    }.GetNewClosure()

    $updateCard = {
        param(
            [Parameter(Mandatory)][object]$Card,
            [Parameter(Mandatory)][object]$Row
        )
        $key = [string](& $state.GetPresentationField $Row -Name 'Key')
        $selected = -not [string]::IsNullOrEmpty($state.FocusKey) -and $state.FocusKey -eq $key

        $surface = $(if ($selected) { $state.Palette.SelectionSurface } else { $state.Palette.SurfaceStrong })
        if ([string]$Card.Background.ToString() -cne $surface) {
            $Card.Background = & $state.CreateBrush $surface
        }
        $edge = $(if ($selected) { $state.Palette.Accent } else { $state.Palette.Separator })
        if ([string]$Card.BorderBrush.ToString() -cne $edge) {
            $Card.BorderBrush = & $state.CreateBrush $edge
        }

        $label = $Card.Resources['Label']
        $remaining = $Card.Resources['Remaining']
        $progress = $Card.Resources['Progress']
        $secondary = $Card.Resources['Secondary']
        $countdown = $Card.Resources['Countdown']
        $resetTime = $Card.Resources['ResetTime']
        $focusButton = $Card.Resources['FocusButton']
        $focusDot = $Card.Resources['FocusDot']

        $labelText = [string](& $state.GetPresentationField $Row -Name 'Label')
        if ([string]$label.Text -cne $labelText) {
            $label.Text = $labelText
            [Windows.Automation.AutomationProperties]::SetName($label, "额度名称：$labelText")
        }

        $inUseDot = $Card.Resources['InUseDot']
        if ($null -ne $inUseDot) {
            $inUse = [bool](& $state.GetPresentationField $Row -Name 'InUse')
            $inUseTarget = if ($inUse) {
                [Windows.Visibility]::Visible
            }
            else {
                [Windows.Visibility]::Collapsed
            }
            if ($inUseDot.Visibility -ne $inUseTarget) {
                $inUseDot.Visibility = $inUseTarget
            }
        }

        $remainingValue = & $state.GetPresentationField $Row -Name 'ValueText'
        if ($null -eq $remainingValue) {
            $remainingValue = & $state.GetPresentationField $Row -Name 'RemainingText'
        }
        $remainingDisplay = & $state.QuotaDisplayText ([string]$remainingValue)
        if ([string]$remaining.Text -cne $remainingDisplay) {
            $remaining.Text = $remainingDisplay
            [Windows.Automation.AutomationProperties]::SetName($remaining, "剩余额度：$remainingDisplay")
        }

        $progressValue = & $state.ConvertProgress (& $state.GetPresentationField $Row -Name 'ProgressValue')
        if ($null -eq $progressValue) {
            if ($progress.Visibility -ne [Windows.Visibility]::Collapsed) {
                $progress.Visibility = [Windows.Visibility]::Collapsed
            }
        }
        else {
            if ($progress.Visibility -ne [Windows.Visibility]::Visible) {
                $progress.Visibility = [Windows.Visibility]::Visible
            }
            if ([double]$progress.Value -ne $progressValue) {
                $progress.Value = $progressValue
            }
        }

        $secondaryText = [string](& $state.GetPresentationField $Row -Name 'SecondaryText')
        if ([string]$secondary.Text -cne $secondaryText) {
            $secondary.Text = $secondaryText
            [Windows.Automation.AutomationProperties]::SetName($secondary, $secondaryText)
        }
        $secondaryTarget = if ([string]::IsNullOrWhiteSpace($secondaryText)) {
            [Windows.Visibility]::Collapsed
        }
        else {
            [Windows.Visibility]::Visible
        }
        if ($secondary.Visibility -ne $secondaryTarget) {
            $secondary.Visibility = $secondaryTarget
        }

        $countdownValue = & $state.GetPresentationField $Row -Name 'Countdown'
        if ($null -eq $countdownValue) {
            $countdownValue = & $state.GetPresentationField $Row -Name 'CountdownText'
        }
        $countdownDisplay = [string]$countdownValue
        if ([string]$countdown.Text -cne $countdownDisplay) {
            $countdown.Text = $countdownDisplay
            [Windows.Automation.AutomationProperties]::SetName($countdown, "重置倒计时：$countdownDisplay")
        }

        $resetValue = & $state.GetPresentationField $Row -Name 'ResetTime'
        if ($null -eq $resetValue) {
            $resetValue = & $state.GetPresentationField $Row -Name 'ResetTimeText'
        }
        $resetDisplay = [string]$resetValue
        if ([string]$resetTime.Text -cne $resetDisplay) {
            $resetTime.Text = $resetDisplay
            [Windows.Automation.AutomationProperties]::SetName($resetTime, $resetDisplay)
        }

        $focusForeground = $(if ($selected) { $state.Palette.Accent } else { $state.Palette.TextSecondary })
        if ([string]$focusButton.Foreground.ToString() -cne $focusForeground) {
            $focusButton.Foreground = & $state.CreateBrush $focusForeground
        }
        $focusBackground = $(if ($selected) { & $state.CreateBrush $state.Palette.AccentSoft } else { [Windows.Media.Brushes]::Transparent })
        if ([string]$focusButton.Background.ToString() -cne [string]$focusBackground.ToString()) {
            $focusButton.Background = $focusBackground
        }
        $focusDotTarget = if ($selected) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        if ($focusDot.Visibility -ne $focusDotTarget) {
            $focusDot.Visibility = $focusDotTarget
        }
        $focusTooltip = if ($selected) { '取消迷你模式固定显示' } else { '设为迷你模式显示项' }
        if ([string]$focusButton.ToolTip -cne $focusTooltip) {
            $focusButton.ToolTip = $focusTooltip
            [Windows.Automation.AutomationProperties]::SetName($focusButton, $focusTooltip)
        }
    }.GetNewClosure()

    $updatePanel = {
        param(
            [Parameter(Mandatory)][Windows.Controls.StackPanel]$Panel,
            [Parameter()][AllowEmptyCollection()][object[]]$Rows = @()
        )

        if ($Rows.Count -eq 0) {
            if ($Panel.Children.Count -eq 1 -and $Panel.Children[0].Tag -eq 'EmptyQuotaState') {
                return
            }
            for ($index = $Panel.Children.Count - 1; $index -ge 0; $index--) {
                & $detachCardHandler $Panel.Children[$index]
            }
            $Panel.Children.Clear()
            $empty = [Windows.Controls.TextBlock]::new()
            $empty.Text = '当前账户未返回额度窗口'
            $empty.Foreground = & $state.CreateBrush $state.Palette.TextSecondary
            $empty.FontSize = 12
            $empty.TextAlignment = [Windows.TextAlignment]::Center
            $empty.TextWrapping = [Windows.TextWrapping]::Wrap
            $empty.Margin = [Windows.Thickness]::new(4, 20, 4, 16)
            $empty.Tag = 'EmptyQuotaState'
            [Windows.Automation.AutomationProperties]::SetName($empty, $empty.Text)
            $Panel.Children.Add($empty) | Out-Null
            return
        }

        # Fast path: the rows are already laid out in the same order. The
        # steady-state 1 Hz refresh lands here and only re-texts the existing
        # cards, so the visual tree is reused instead of rebuilt and no
        # reconcile allocation churns per tick.
        if ($Panel.Children.Count -eq $Rows.Count) {
            $matches = $true
            for ($index = 0; $index -lt $Rows.Count; $index++) {
                $key = [string](& $state.GetPresentationField $Rows[$index] -Name 'Key')
                if ([string]$Panel.Children[$index].Tag -cne $key) {
                    $matches = $false
                    break
                }
            }
            if ($matches) {
                for ($index = 0; $index -lt $Rows.Count; $index++) {
                    & $updateCard -Card $Panel.Children[$index] -Row $Rows[$index]
                }
                return
            }
        }

        # Slow path: rows were added, removed, or reordered. Reconcile by key.
        $desiredKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $Rows) {
            $null = $desiredKeys.Add([string](& $state.GetPresentationField $row -Name 'Key'))
        }

        $existing = [ordered]@{}
        for ($index = $Panel.Children.Count - 1; $index -ge 0; $index--) {
            $child = $Panel.Children[$index]
            $tag = [string]$child.Tag
            if ([string]::IsNullOrEmpty($tag) -or $tag -eq 'EmptyQuotaState') {
                & $detachCardHandler $child
                $Panel.Children.RemoveAt($index)
                continue
            }
            if (-not $desiredKeys.Contains($tag)) {
                & $detachCardHandler $child
                $Panel.Children.RemoveAt($index)
                continue
            }
            $existing[$tag] = $child
        }

        $insertIndex = 0
        foreach ($row in $Rows) {
            $key = [string](& $state.GetPresentationField $row -Name 'Key')
            $card = $existing[$key]
            if ($null -eq $card) {
                $card = & $state.CreateQuotaCard -PresentationRow $row -Palette $state.Palette `
                    -FocusButtonStyle $state.FocusButtonStyle `
                    -OnFocusRequested $focusRequest -SelectedKey $state.FocusKey
                $Panel.Children.Insert($insertIndex, $card)
            }
            else {
                $currentIndex = $Panel.Children.IndexOf($card)
                if ($currentIndex -ne $insertIndex) {
                    $Panel.Children.RemoveAt($currentIndex)
                    $Panel.Children.Insert($insertIndex, $card)
                }
                & $updateCard -Card $card -Row $row
            }
            $insertIndex++
        }
    }.GetNewClosure()

    $removeFocusHandlers = {
        foreach ($panel in @(
            $state.Controls.OfficialRows, $state.Controls.RelayRows,
            $state.Controls.OfficialTabRows, $state.Controls.RelayTabRows
        )) {
            if ($null -eq $panel) { continue }
            foreach ($child in $panel.Children) {
                & $detachCardHandler $child
            }
        }
    }.GetNewClosure()

    $renderSnapshot = {
        if ($state.Disposed) { return }
        & $updatePanel $state.Controls.OfficialRows $state.OfficialRows
        & $updatePanel $state.Controls.RelayRows $state.RelayRows
        & $updatePanel $state.Controls.OfficialTabRows $state.OfficialRows
        & $updatePanel $state.Controls.RelayTabRows $state.RelayRows
        $state.Controls.RootBorder.InvalidateMeasure()
    }.GetNewClosure()

    $renderGroups = {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OfficialRows,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RelayRows,
            [Parameter()][AllowNull()][string]$FocusKey = $state.FocusKey,
            [Parameter()][Alias('State')][AllowNull()][object]$ConnectionState = $state.ConnectionState
        )
        if ($state.Disposed) { return }
        $state.OfficialRows = [object[]]@($OfficialRows | Where-Object { $null -ne $_ })
        $state.RelayRows = [object[]]@($RelayRows | Where-Object { $null -ne $_ })
        $state.FocusKey = $FocusKey
        $state.ConnectionState = $ConnectionState
        & $renderSnapshot
    }.GetNewClosure()

    $render = {
        param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$PresentationRows)
        & $renderGroups -OfficialRows $PresentationRows -RelayRows @()
    }.GetNewClosure()

    $setTheme = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed) { return }
        $state.Theme = $Theme
        $state.Palette = & $state.ApplyTheme -Window $state.Window -Controls $state.Controls -Theme $Theme
        if ($state.FreshnessIsLive -eq $true) {
            $state.Controls.ConnectionDot.Background = & $state.CreateBrush '#FF22C55E'
        }
        & $renderSnapshot
        & $updateLayoutVisuals
    }.GetNewClosure()

    $setLayout = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Overview', 'Tabs')][string]$FullLayout)
        if ($state.Disposed) { return }
        $state.FullLayout = $FullLayout
        & $renderSnapshot
        & $updateLayoutVisuals
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
        if ($state.Disposed) { return }
        $state.Window.Topmost = $Topmost
        $label = $(if ($Topmost) { '取消始终置顶' } else { '始终置顶' })
        $state.Controls.PinButton.ToolTip = $label
        [Windows.Automation.AutomationProperties]::SetName($state.Controls.PinButton, $label)
    }.GetNewClosure()

    $setFreshness = {
        param(
            [Parameter(Mandatory, Position = 0)][bool]$IsLive,
            [Parameter(Position = 1)][AllowNull()][string]$Text
        )
        if ($state.Disposed) { return }
        $state.FreshnessIsLive = $IsLive
        if ($IsLive) {
            $state.Controls.ConnectionDot.Background = & $state.CreateBrush '#FF22C55E'
            $state.Controls.ConnectionDot.ToolTip = 'Codex 额度数据实时'
            [Windows.Automation.AutomationProperties]::SetName($state.Controls.ConnectionDot, '连接状态：实时')
            $state.Controls.FreshnessText.Text = ''
            $state.Controls.FreshnessText.Visibility = [Windows.Visibility]::Collapsed
        }
        else {
            $state.Controls.ConnectionDot.Background = & $state.CreateBrush $state.Palette.TextSecondary
            $state.Controls.ConnectionDot.ToolTip = 'Codex 额度数据已过期'
            [Windows.Automation.AutomationProperties]::SetName($state.Controls.ConnectionDot, '连接状态：数据已过期')
            $state.Controls.FreshnessText.Text = [string]$Text
            $state.Controls.FreshnessText.Visibility = [Windows.Visibility]::Visible
        }
    }.GetNewClosure()

    $getPlacement = {
        if ($state.Disposed -or $null -eq $state.Window) { return $null }
        return & $state.GetPlacementModel -Window $state.Window
    }.GetNewClosure()

    $setCallbacks = {
        param(
            [Parameter()][AllowNull()][scriptblock]$OnDrag,
            [Parameter()][AllowNull()][scriptblock]$OnToggleTopmost,
            [Parameter()][AllowNull()][scriptblock]$OnHide,
            [Parameter()][AllowNull()][scriptblock]$OnCloseRequested,
            [Parameter()][AllowNull()][scriptblock]$OnThemeRequested,
            [Parameter()][AllowNull()][scriptblock]$OnModeRequested,
            [Parameter()][AllowNull()][scriptblock]$OnLayoutRequested,
            [Parameter()][AllowNull()][scriptblock]$OnFocusRequested,
            [Parameter()][AllowNull()][scriptblock]$OnRefreshRequested
        )
        if ($state.Disposed) { return }
        $state.Callbacks = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnToggleTopmost = $OnToggleTopmost
            OnHide = $OnHide
            OnCloseRequested = $OnCloseRequested
            OnThemeRequested = $OnThemeRequested
            OnModeRequested = $OnModeRequested
            OnLayoutRequested = $OnLayoutRequested
            OnRefreshRequested = $OnRefreshRequested
            OnFocusRequested = $OnFocusRequested
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
            $targetControls.HeaderDragArea.Remove_MouseLeftButtonDown($delegates.MouseLeftButtonDown)
            $targetControls.PinButton.Remove_Click($delegates.PinClick)
            $targetControls.ThemeButton.Remove_Click($delegates.ThemeClick)
            $targetControls.ModeButton.Remove_Click($delegates.ModeClick)
            $targetControls.LayoutButton.Remove_Click($delegates.LayoutClick)
            $targetControls.RefreshButton.Remove_Click($delegates.RefreshClick)
            $targetControls.HideButton.Remove_Click($delegates.HideClick)
            $targetControls.CloseButton.Remove_Click($delegates.CloseClick)
            $targetControls.OfficialTabButton.Remove_Click($delegates.OfficialTabClick)
            $targetControls.RelayTabButton.Remove_Click($delegates.RelayTabClick)
            & $removeFocusHandlers
        }
        if ($null -ne $targetWindow -and $null -ne $delegates) {
            $targetWindow.Remove_Closing($delegates.Closing)
        }

        $state.Callbacks = $null
        $state.DragAction = $null
        $state.CreateBrush = $null
        $state.CreateQuotaCard = $null
        $state.GetPlacementModel = $null
        $state.ApplyTheme = $null
        if ($null -ne $delegates) { $delegates.Clear() }

        if ($null -ne $targetWindow) {
            try { $targetWindow.Close() }
            catch [InvalidOperationException] {
                # A WPF Window that was already closed has no remaining native resources.
            }
        }
        $state.Window = $null
        $state.Controls = $null
    }.GetNewClosure()

    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        Show = $show
        Hide = $hide
        Activate = $activate
        SetTopmost = $setTopmost
        Render = $render
        RenderGroups = $renderGroups
        SetTheme = $setTheme
        SetLayout = $setLayout
        SetFreshness = $setFreshness
        GetPlacement = $getPlacement
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}

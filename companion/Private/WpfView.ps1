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
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    )) {
        return $null
    }

    try {
        [double]$progress = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($progress) -or
            [double]::IsInfinity($progress) -or
            $progress -lt 0.0 -or
            $progress -gt 100.0) {
            return $null
        }

        return [double]$progress
    }
    catch {
        return $null
    }
}

function New-WpfQuotaCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$PresentationRow
    )

    $card = [Windows.Controls.Border]::new()
    $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#66263244')
    $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(10)
    $card.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $card.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
    $card.Tag = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'Key')

    $grid = [Windows.Controls.Grid]::new()
    foreach ($height in @('Auto', 'Auto', 'Auto')) {
        $definition = [Windows.Controls.RowDefinition]::new()
        $definition.Height = [Windows.GridLengthConverter]::new().ConvertFromString($height)
        $grid.RowDefinitions.Add($definition)
    }

    $heading = [Windows.Controls.Grid]::new()
    $labelColumn = [Windows.Controls.ColumnDefinition]::new()
    $labelColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $heading.ColumnDefinitions.Add($labelColumn)
    $remainingColumn = [Windows.Controls.ColumnDefinition]::new()
    $remainingColumn.Width = [Windows.GridLength]::Auto
    $heading.ColumnDefinitions.Add($remainingColumn)

    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'Label')
    $label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $label.FontSize = 12
    $label.FontWeight = [Windows.FontWeights]::SemiBold
    $label.TextWrapping = [Windows.TextWrapping]::Wrap
    $label.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $label.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $label.Tag = 'QuotaLabel'
    [Windows.Automation.AutomationProperties]::SetName($label, "额度名称：$($label.Text)")
    [Windows.Controls.Grid]::SetColumn($label, 0)
    $heading.Children.Add($label) | Out-Null

    $remaining = [Windows.Controls.TextBlock]::new()
    $remaining.Text = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'RemainingText')
    $remaining.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    $remaining.FontSize = 24
    $remaining.FontWeight = [Windows.FontWeights]::Bold
    $remaining.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $remaining.Tag = 'QuotaRemaining'
    [Windows.Automation.AutomationProperties]::SetName($remaining, "剩余额度：$($remaining.Text)")
    [Windows.Controls.Grid]::SetColumn($remaining, 1)
    $heading.Children.Add($remaining) | Out-Null
    [Windows.Controls.Grid]::SetRow($heading, 0)
    $grid.Children.Add($heading) | Out-Null

    $progressBar = [Windows.Controls.ProgressBar]::new()
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Height = 6
    $progressBar.Margin = [Windows.Thickness]::new(0, 7, 0, 7)
    $progressBar.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
    $progressBar.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#10A37F')
    $progressBar.Tag = 'QuotaProgress'
    [Windows.Automation.AutomationProperties]::SetName($progressBar, '剩余额度进度')
    $progressValue = ConvertTo-WpfProgressValue -Value (
        Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'ProgressValue'
    )
    if ($null -eq $progressValue) {
        $progressBar.Visibility = [Windows.Visibility]::Collapsed
    }
    else {
        $progressBar.Value = $progressValue
        $progressBar.Visibility = [Windows.Visibility]::Visible
    }
    [Windows.Controls.Grid]::SetRow($progressBar, 1)
    $grid.Children.Add($progressBar) | Out-Null

    $timing = [Windows.Controls.Grid]::new()
    $countdownColumn = [Windows.Controls.ColumnDefinition]::new()
    $countdownColumn.Width = [Windows.GridLength]::Auto
    $timing.ColumnDefinitions.Add($countdownColumn)
    $resetColumn = [Windows.Controls.ColumnDefinition]::new()
    $resetColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $timing.ColumnDefinitions.Add($resetColumn)

    $countdown = [Windows.Controls.TextBlock]::new()
    $countdown.Text = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'CountdownText')
    $countdown.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#A7F3D0')
    $countdown.FontSize = 11
    $countdown.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $countdown.Tag = 'QuotaCountdown'
    [Windows.Automation.AutomationProperties]::SetName($countdown, "重置倒计时：$($countdown.Text)")
    [Windows.Controls.Grid]::SetColumn($countdown, 0)
    $timing.Children.Add($countdown) | Out-Null

    $resetTime = [Windows.Controls.TextBlock]::new()
    $resetTime.Text = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'ResetTimeText')
    $resetTime.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#94A3B8')
    $resetTime.FontSize = 10
    $resetTime.TextAlignment = [Windows.TextAlignment]::Right
    $resetTime.TextWrapping = [Windows.TextWrapping]::Wrap
    $resetTime.Tag = 'QuotaResetTime'
    [Windows.Automation.AutomationProperties]::SetName($resetTime, $resetTime.Text)
    [Windows.Controls.Grid]::SetColumn($resetTime, 1)
    $timing.Children.Add($resetTime) | Out-Null
    [Windows.Controls.Grid]::SetRow($timing, 2)
    $grid.Children.Add($timing) | Out-Null

    $card.Child = $grid
    return $card
}

function Get-WpfQuotaWindowPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Windows.Window]$Window
    )

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

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnDrag,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnToggleTopmost,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnHide,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnCloseRequested,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$DragAction
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
            $resolvedXamlPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $readerSettings = [Xml.XmlReaderSettings]::new()
        $readerSettings.CloseInput = $false
        $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $reader = [Xml.XmlReader]::Create($stream, $readerSettings)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($window -isnot [Windows.Window]) {
        throw 'The Codex quota floating-window XAML root must be a Window.'
    }

    $controlNames = @(
        'RootBorder',
        'HeaderDragArea',
        'ConnectionDot',
        'TitleText',
        'PinButton',
        'HideButton',
        'CloseButton',
        'QuotaRows',
        'FreshnessText'
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
        Callbacks = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnToggleTopmost = $OnToggleTopmost
            OnHide = $OnHide
            OnCloseRequested = $OnCloseRequested
        }
        DragAction = $DragAction
        CreateQuotaCard = ${function:New-WpfQuotaCard}
        GetPlacementModel = ${function:Get-WpfQuotaWindowPlacement}
        Delegates = [ordered]@{}
    }

    $mouseHandlerScript = {
        param($sender, $eventArgs)

        if ($state.Disposed -or $eventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left) {
            return
        }

        & $state.DragAction $state.Window
        $callbacks = $state.Callbacks
        if ($null -ne $callbacks -and $null -ne $callbacks.OnDrag) {
            $placement = & $state.GetPlacementModel -Window $state.Window
            & $callbacks.OnDrag $placement
        }
    }.GetNewClosure()
    $state.Delegates.MouseLeftButtonDown = [Windows.Input.MouseButtonEventHandler]$mouseHandlerScript

    $pinHandlerScript = {
        param($sender, $eventArgs)

        if ($state.Disposed) {
            return
        }

        $callbacks = $state.Callbacks
        if ($null -ne $callbacks -and $null -ne $callbacks.OnToggleTopmost) {
            & $callbacks.OnToggleTopmost
        }
    }.GetNewClosure()
    $state.Delegates.PinClick = [Windows.RoutedEventHandler]$pinHandlerScript

    $hideHandlerScript = {
        param($sender, $eventArgs)

        if ($state.Disposed) {
            return
        }

        $callbacks = $state.Callbacks
        if ($null -ne $callbacks -and $null -ne $callbacks.OnHide) {
            & $callbacks.OnHide
        }
    }.GetNewClosure()
    $state.Delegates.HideClick = [Windows.RoutedEventHandler]$hideHandlerScript

    $closeHandlerScript = {
        param($sender, $eventArgs)

        if ($state.Disposed) {
            return
        }

        $callbacks = $state.Callbacks
        if ($null -ne $callbacks -and $null -ne $callbacks.OnCloseRequested) {
            & $callbacks.OnCloseRequested
        }
    }.GetNewClosure()
    $state.Delegates.CloseClick = [Windows.RoutedEventHandler]$closeHandlerScript

    $closingHandlerScript = {
        param($sender, [ComponentModel.CancelEventArgs]$eventArgs)

        if ($state.AllowExit -or $state.Disposed) {
            return
        }

        $eventArgs.Cancel = $true
        $callbacks = $state.Callbacks
        if ($null -ne $callbacks -and $null -ne $callbacks.OnCloseRequested) {
            & $callbacks.OnCloseRequested
        }
    }.GetNewClosure()
    $state.Delegates.Closing = [ComponentModel.CancelEventHandler]$closingHandlerScript

    $controls.HeaderDragArea.Add_MouseLeftButtonDown($state.Delegates.MouseLeftButtonDown)
    $controls.PinButton.Add_Click($state.Delegates.PinClick)
    $controls.HideButton.Add_Click($state.Delegates.HideClick)
    $controls.CloseButton.Add_Click($state.Delegates.CloseClick)
    $window.Add_Closing($state.Delegates.Closing)

    $show = {
        if (-not $state.Disposed) {
            $state.Window.Show()
        }
    }.GetNewClosure()

    $hide = {
        if (-not $state.Disposed) {
            $state.Window.Hide()
        }
    }.GetNewClosure()

    $activate = {
        if (-not $state.Disposed) {
            if (-not $state.Window.IsVisible) {
                $state.Window.Show()
            }
            if ($state.Window.WindowState -eq [Windows.WindowState]::Minimized) {
                $state.Window.WindowState = [Windows.WindowState]::Normal
            }
            $state.Window.Activate() | Out-Null
        }
    }.GetNewClosure()

    $setTopmost = {
        param(
            [Parameter(Mandatory, Position = 0)]
            [bool]$Topmost
        )

        if ($state.Disposed) {
            return
        }

        $state.Window.Topmost = $Topmost
        if ($Topmost) {
            $state.Controls.PinButton.ToolTip = '取消始终置顶'
            [Windows.Automation.AutomationProperties]::SetName(
                $state.Controls.PinButton,
                '取消始终置顶'
            )
        }
        else {
            $state.Controls.PinButton.ToolTip = '始终置顶'
            [Windows.Automation.AutomationProperties]::SetName(
                $state.Controls.PinButton,
                '始终置顶'
            )
        }
    }.GetNewClosure()

    $render = {
        param(
            [Parameter(Mandatory, Position = 0)]
            [AllowEmptyCollection()]
            [object[]]$PresentationRows
        )

        if ($state.Disposed) {
            return
        }

        $state.Controls.QuotaRows.Children.Clear()
        $invalidateQuotaLayout = {
            $element = $state.Controls.QuotaRows
            while ($null -ne $element -and $element -is [Windows.UIElement]) {
                $element.InvalidateMeasure()
                if ($element -is [Windows.FrameworkElement]) {
                    $element = $element.Parent
                }
                else {
                    $element = $null
                }
            }
        }
        $rows = @($PresentationRows | Where-Object { $null -ne $_ })
        if ($rows.Count -eq 0) {
            $empty = [Windows.Controls.TextBlock]::new()
            $empty.Text = '当前账户未返回额度窗口'
            $empty.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
            $empty.FontSize = 12
            $empty.TextAlignment = [Windows.TextAlignment]::Center
            $empty.TextWrapping = [Windows.TextWrapping]::Wrap
            $empty.Margin = [Windows.Thickness]::new(4, 20, 4, 16)
            $empty.Tag = 'EmptyQuotaState'
            [Windows.Automation.AutomationProperties]::SetName($empty, $empty.Text)
            $state.Controls.QuotaRows.Children.Add($empty) | Out-Null
            & $invalidateQuotaLayout
            return
        }

        foreach ($row in $rows) {
            $card = & $state.CreateQuotaCard -PresentationRow $row
            $state.Controls.QuotaRows.Children.Add($card) | Out-Null
        }
        & $invalidateQuotaLayout
    }.GetNewClosure()

    $setFreshness = {
        param(
            [Parameter(Mandatory, Position = 0)]
            [bool]$IsLive,

            [Parameter(Position = 1)]
            [AllowNull()]
            [string]$Text
        )

        if ($state.Disposed) {
            return
        }

        if ($IsLive) {
            $state.Controls.ConnectionDot.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
            $state.Controls.ConnectionDot.ToolTip = 'Codex 额度数据实时'
            [Windows.Automation.AutomationProperties]::SetName(
                $state.Controls.ConnectionDot,
                '连接状态：实时'
            )
            $state.Controls.FreshnessText.Text = ''
            $state.Controls.FreshnessText.Visibility = [Windows.Visibility]::Collapsed
        }
        else {
            $state.Controls.ConnectionDot.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#94A3B8')
            $state.Controls.ConnectionDot.ToolTip = 'Codex 额度数据已过期'
            [Windows.Automation.AutomationProperties]::SetName(
                $state.Controls.ConnectionDot,
                '连接状态：数据已过期'
            )
            $state.Controls.FreshnessText.Text = [string]$Text
            $state.Controls.FreshnessText.Visibility = [Windows.Visibility]::Visible
        }
    }.GetNewClosure()

    $getPlacement = {
        if ($state.Disposed -or $null -eq $state.Window) {
            return $null
        }

        return & $state.GetPlacementModel -Window $state.Window
    }.GetNewClosure()

    $setCallbacks = {
        param(
            [Parameter()]
            [AllowNull()]
            [scriptblock]$OnDrag,

            [Parameter()]
            [AllowNull()]
            [scriptblock]$OnToggleTopmost,

            [Parameter()]
            [AllowNull()]
            [scriptblock]$OnHide,

            [Parameter()]
            [AllowNull()]
            [scriptblock]$OnCloseRequested
        )

        if ($state.Disposed) {
            return
        }

        $replacement = [pscustomobject][ordered]@{
            OnDrag = $OnDrag
            OnToggleTopmost = $OnToggleTopmost
            OnHide = $OnHide
            OnCloseRequested = $OnCloseRequested
        }
        $state.Callbacks = $replacement
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) {
            return
        }

        $state.Disposed = $true
        $state.AllowExit = $true

        $targetWindow = $state.Window
        $targetControls = $state.Controls
        $delegates = $state.Delegates
        if ($null -ne $targetControls -and $null -ne $delegates) {
            $targetControls.HeaderDragArea.Remove_MouseLeftButtonDown($delegates.MouseLeftButtonDown)
            $targetControls.PinButton.Remove_Click($delegates.PinClick)
            $targetControls.HideButton.Remove_Click($delegates.HideClick)
            $targetControls.CloseButton.Remove_Click($delegates.CloseClick)
        }
        if ($null -ne $targetWindow -and $null -ne $delegates) {
            $targetWindow.Remove_Closing($delegates.Closing)
        }

        $state.Callbacks = $null
        $state.DragAction = $null
        $state.CreateQuotaCard = $null
        $state.GetPlacementModel = $null
        if ($null -ne $delegates) {
            $delegates.Clear()
        }

        if ($null -ne $targetWindow) {
            try {
                $targetWindow.Close()
            }
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
        SetFreshness = $setFreshness
        GetPlacement = $getPlacement
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}

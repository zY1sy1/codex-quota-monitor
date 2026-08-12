function Get-CcSwitchImportViewField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}

function Get-CcSwitchImportComboTag {
    param([Parameter(Mandatory)][Windows.Controls.ComboBox]$ComboBox)
    if ($ComboBox.SelectedItem -is [Windows.Controls.ComboBoxItem]) {
        return [string]$ComboBox.SelectedItem.Tag
    }
    return [string]$ComboBox.SelectedItem
}

function New-CcSwitchImportView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\CcSwitchImport.xaml'),

        [Parameter()]
        [AllowNull()]
        [scriptblock]$CustomImportPrompt
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'The CC Switch import dialog requires an STA thread.'
    }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "CC Switch import XAML was not found: $XamlPath"
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            [IO.Path]::GetFullPath($XamlPath), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read
        )
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $reader = [Xml.XmlReader]::Create($stream, $settings)
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
        throw 'CC Switch import XAML root must be a Window.'
    }

    $controlNames = @(
        'SourceList','RefreshButton','StatusText','EndpointComboBox','ConversionText',
        'ImportModeComboBox','UpdateRadioButton','CopyRadioButton','ImportButton','CancelButton'
    )
    $controls = [ordered]@{}
    foreach ($name in $controlNames) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            $window.Close()
            throw "CC Switch import XAML is missing named control '$name'."
        }
        $controls[$name] = $control
    }

    if ($null -eq $CustomImportPrompt) {
        $CustomImportPrompt = {
            param([string]$DisplayName)
            [Windows.MessageBox]::Show(
                ('“{0}”的请求无法安全转换为 Generic。是否保留完整脚本并作为 Custom 导入？' -f $DisplayName),
                '确认 Custom 导入',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Warning
            ) -eq [Windows.MessageBoxResult]::Yes
        }
    }

    $state = [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        Sources = @()
        Details = $null
        Callbacks = $null
        Busy = $false
        Disposed = $false
        SuppressEvents = $false
        CustomImportPrompt = $CustomImportPrompt
        Delegates = [ordered]@{}
    }
    $getField = ${function:Get-CcSwitchImportViewField}
    $getComboTag = ${function:Get-CcSwitchImportComboTag}

    $invoke = {
        param([string]$Name)
        if ($state.Disposed -or $state.SuppressEvents -or $null -eq $state.Callbacks) {
            return $null
        }
        $callback = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $callback -and $callback.Value -is [scriptblock]) {
            return & $callback.Value
        }
        return $null
    }.GetNewClosure()

    $updateImportButton = {
        if ($state.Disposed) {
            return
        }
        $hasSource = $null -ne $controls.SourceList.SelectedItem
        $endpoint = [string]$controls.EndpointComboBox.Text
        $canImport = $null -ne $state.Details -and [bool]$state.Details.CanImport
        if ($canImport -and [bool]$state.Details.RequiresEndpointSelection) {
            $canImport = @($state.Details.EndpointCandidates) -ccontains $endpoint
        }
        $controls.ImportButton.IsEnabled = [bool](
            -not $state.Busy -and $hasSource -and $canImport -and
            -not [string]::IsNullOrWhiteSpace($endpoint)
        )
    }.GetNewClosure()

    $showDialog = {
        if (-not $state.Disposed) {
            return $state.Window.ShowDialog()
        }
    }.GetNewClosure()

    $setSources = {
        param([AllowEmptyCollection()][object[]]$Sources)
        if ($state.Disposed) {
            return
        }
        $safeSources = [Collections.Generic.List[object]]::new()
        foreach ($source in @($Sources)) {
            $rawEndpoints = & $getField $source 'EndpointCandidates'
            $safeSources.Add([pscustomobject][ordered]@{
                SourceProviderId = [string](& $getField $source 'SourceProviderId')
                SourceAppType = [string](& $getField $source 'SourceAppType')
                DisplayName = [string](& $getField $source 'DisplayName')
                ImportStatus = [string](& $getField $source 'ImportStatus')
                EndpointCandidates = [string[]]@($rawEndpoints | ForEach-Object { [string]$_ })
            })
        }
        $state.SuppressEvents = $true
        try {
            $state.Sources = [object[]]$safeSources.ToArray()
            $controls.SourceList.ItemsSource = $state.Sources
            $controls.SourceList.SelectedIndex = if ($state.Sources.Count -gt 0) { 0 } else { -1 }
        }
        finally {
            $state.SuppressEvents = $false
        }
        $null = & $invoke 'OnSelectionChanged'
        & $updateImportButton
    }.GetNewClosure()

    $getSelection = {
        if ($state.Disposed -or $null -eq $controls.SourceList.SelectedItem) {
            return $null
        }
        $source = $controls.SourceList.SelectedItem
        [pscustomobject][ordered]@{
            SourceProviderId = [string](& $getField $source 'SourceProviderId')
            SourceAppType = [string](& $getField $source 'SourceAppType')
            Endpoint = [string]$controls.EndpointComboBox.Text
            ImportMode = & $getComboTag $controls.ImportModeComboBox
            Action = if ([bool]$controls.UpdateRadioButton.IsChecked) { 'Update' } else { 'Copy' }
        }
    }.GetNewClosure()

    $setSelectionDetails = {
        param([AllowNull()][object]$Details)
        if ($state.Disposed) {
            return
        }
        if ($null -eq $Details) {
            $state.Details = $null
            $controls.EndpointComboBox.ItemsSource = $null
            $controls.EndpointComboBox.Text = ''
            $controls.ConversionText.Text = ''
            & $updateImportButton
            return
        }
        $endpointCandidates = [string[]]@(
            (& $getField $Details 'EndpointCandidates') | ForEach-Object { [string]$_ }
        )
        $selectedEndpoint = [string](& $getField $Details 'SelectedEndpoint')
        $state.Details = [pscustomobject][ordered]@{
            EndpointCandidates = $endpointCandidates
            SelectedEndpoint = $selectedEndpoint
            ConversionText = [string](& $getField $Details 'ConversionText')
            CanImport = [bool](& $getField $Details 'CanImport')
            CanUpdate = [bool](& $getField $Details 'CanUpdate')
            DefaultAction = [string](& $getField $Details 'DefaultAction')
            AllowEndpointEntry = [bool](& $getField $Details 'AllowEndpointEntry')
            RequiresEndpointSelection = [bool](& $getField $Details 'RequiresEndpointSelection')
        }
        $state.SuppressEvents = $true
        try {
            $controls.EndpointComboBox.ItemsSource = $endpointCandidates
            $controls.EndpointComboBox.IsEditable = $state.Details.AllowEndpointEntry
            $controls.EndpointComboBox.SelectedIndex = -1
            $controls.EndpointComboBox.Text = $selectedEndpoint
            $controls.ConversionText.Text = $state.Details.ConversionText
            $controls.UpdateRadioButton.IsEnabled = $state.Details.CanUpdate
            $controls.UpdateRadioButton.IsChecked = $state.Details.DefaultAction -ceq 'Update'
            $controls.CopyRadioButton.IsChecked = $state.Details.DefaultAction -cne 'Update'
            $controls.ImportModeComboBox.IsEnabled = $state.Details.CanImport
        }
        finally {
            $state.SuppressEvents = $false
        }
        & $updateImportButton
    }.GetNewClosure()

    $setBusy = {
        param([bool]$Busy)
        if ($state.Disposed) {
            return
        }
        $state.Busy = $Busy
        $controls.RefreshButton.IsEnabled = -not $Busy
        $controls.SourceList.IsEnabled = -not $Busy
        $controls.EndpointComboBox.IsEnabled = -not $Busy
        & $updateImportButton
    }.GetNewClosure()

    $setStatus = {
        param([AllowNull()][string]$Message)
        if (-not $state.Disposed) {
            $controls.StatusText.Text = if ($null -eq $Message) { '' } else { $Message }
        }
    }.GetNewClosure()

    $confirmCustomImport = {
        param([AllowNull()][string]$DisplayName)
        if ($state.Disposed) {
            return $false
        }
        $safeName = if ([string]::IsNullOrWhiteSpace($DisplayName)) { '所选规则' } else { $DisplayName }
        return [bool](& $state.CustomImportPrompt $safeName)
    }.GetNewClosure()

    $setCallbacks = {
        param($OnRefresh, $OnSelectionChanged, $OnImport, $OnCancel)
        if (-not $state.Disposed) {
            $state.Callbacks = [pscustomobject][ordered]@{
                OnRefresh = $OnRefresh
                OnSelectionChanged = $OnSelectionChanged
                OnImport = $OnImport
                OnCancel = $OnCancel
            }
        }
    }.GetNewClosure()

    $refreshClick = [Windows.RoutedEventHandler]{
        param($sender, $args)
        $null = & $invoke 'OnRefresh'
    }.GetNewClosure()
    $selectionChanged = [Windows.Controls.SelectionChangedEventHandler]{
        param($sender, $args)
        $null = & $invoke 'OnSelectionChanged'
        & $updateImportButton
    }.GetNewClosure()
    $endpointTextChanged = [Windows.Controls.TextChangedEventHandler]{
        param($sender, $args)
        & $updateImportButton
    }.GetNewClosure()
    $importClick = [Windows.RoutedEventHandler]{
        param($sender, $args)
        if ((& $invoke 'OnImport') -eq $true) {
            $state.Window.Hide()
        }
    }.GetNewClosure()
    $cancelClick = [Windows.RoutedEventHandler]{
        param($sender, $args)
        if ((& $invoke 'OnCancel') -eq $true) {
            $state.Window.Hide()
        }
    }.GetNewClosure()
    $closing = [ComponentModel.CancelEventHandler]{
        param($sender, $args)
        if (-not $state.Disposed) {
            $args.Cancel = $true
            $null = & $invoke 'OnCancel'
            $state.Window.Hide()
        }
    }.GetNewClosure()

    $state.Delegates.RefreshClick = $refreshClick
    $state.Delegates.SelectionChanged = $selectionChanged
    $state.Delegates.EndpointTextChanged = $endpointTextChanged
    $state.Delegates.ImportClick = $importClick
    $state.Delegates.CancelClick = $cancelClick
    $state.Delegates.Closing = $closing
    $controls.RefreshButton.Add_Click($refreshClick)
    $controls.SourceList.Add_SelectionChanged($selectionChanged)
    $controls.EndpointComboBox.Add_SelectionChanged($selectionChanged)
    $controls.EndpointComboBox.AddHandler(
        [Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        $endpointTextChanged,
        $true
    )
    $controls.ImportButton.Add_Click($importClick)
    $controls.CancelButton.Add_Click($cancelClick)
    $window.Add_Closing($closing)

    $dispose = {
        if ($state.Disposed) {
            return
        }
        $state.Disposed = $true
        $controls.RefreshButton.Remove_Click($state.Delegates.RefreshClick)
        $controls.SourceList.Remove_SelectionChanged($state.Delegates.SelectionChanged)
        $controls.EndpointComboBox.Remove_SelectionChanged($state.Delegates.SelectionChanged)
        $controls.EndpointComboBox.RemoveHandler(
            [Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
            $state.Delegates.EndpointTextChanged
        )
        $controls.ImportButton.Remove_Click($state.Delegates.ImportClick)
        $controls.CancelButton.Remove_Click($state.Delegates.CancelClick)
        $window.Remove_Closing($state.Delegates.Closing)
        $state.Callbacks = $null
        $state.CustomImportPrompt = $null
        $state.Sources = @()
        $state.Details = $null
        try {
            $window.Close()
        }
        catch [InvalidOperationException] {
        }
    }.GetNewClosure()

    $controls.ImportModeComboBox.SelectedIndex = 0
    $controls.CopyRadioButton.IsChecked = $true
    $controls.ImportButton.IsEnabled = $false
    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        ShowDialog = $showDialog
        SetSources = $setSources
        GetSelection = $getSelection
        SetSelectionDetails = $setSelectionDetails
        SetBusy = $setBusy
        SetStatus = $setStatus
        ConfirmCustomImport = $confirmCustomImport
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}

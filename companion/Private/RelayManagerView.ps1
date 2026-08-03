function Get-RelayManagerField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-RelayManagerTemplateValue {
    param([Parameter(Mandatory)][Windows.Controls.ComboBox]$ComboBox)
    $item = $ComboBox.SelectedItem
    if ($item -is [Windows.Controls.ComboBoxItem]) { return [string]$item.Tag }
    return [string]$item
}

function Test-RelayManagerBuiltInDraft {
    param(
        [AllowNull()][string]$TemplateType,
        [AllowNull()][string]$BaseUrl,
        [AllowNull()][string]$Script
    )
    if ($TemplateType -eq 'Custom') { return $true }
    if ($TemplateType -notin @('Wakaka', 'General', 'NewApi')) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Script) -or $Script -cnotmatch '\{\{baseUrl\}\}') {
        return $false
    }
    $withoutBasePlaceholder = $Script -replace '\{\{baseUrl\}\}', ''
    return $withoutBasePlaceholder -cnotmatch '(?i)https?\s*:\s*[\\/]'
}

function ConvertTo-RelayTrustDisplayOrigin {
    param([AllowNull()][string]$Destination)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Destination) -or
        -not [Uri]::TryCreate($Destination, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $null
    }
    $canonicalHost = if ($uri.HostNameType -eq [UriHostNameType]::IPv6) { "[$($uri.Host)]" } else { $uri.IdnHost }
    $port = if ($uri.IsDefaultPort) {
        if ($uri.Scheme -eq 'https') { 443 } else { 80 }
    }
    else { $uri.Port }
    return "$($uri.Scheme.ToLowerInvariant())://$($canonicalHost.ToLowerInvariant()):$port"
}

function New-RelayManagerView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\RelayManager.xaml'),

        [Parameter()]
        [AllowNull()]
        [scriptblock]$TrustPrompt
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'The relay provider manager requires an STA thread.'
    }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "Relay manager XAML was not found: $XamlPath"
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
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($window -isnot [Windows.Window]) { throw 'Relay manager XAML root must be a Window.' }

    $controlNames = @(
        'ProviderList', 'AddButton', 'EditButton', 'DuplicateButton', 'DeleteButton',
        'EnabledCheckBox', 'NameTextBox', 'BaseUrlTextBox', 'TemplateComboBox',
        'ScriptTextBox', 'ApiKeyPasswordBox', 'AccessTokenPasswordBox', 'UserIdPasswordBox',
        'TimeoutTextBox', 'IntervalTextBox', 'TestButton', 'TestStateText', 'SaveButton',
        'CancelButton', 'PreviewList'
    )
    $controls = [ordered]@{}
    foreach ($name in $controlNames) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            $window.Close()
            throw "Relay manager XAML is missing named control '$name'."
        }
        $controls[$name] = $control
    }

    if ($null -eq $TrustPrompt) {
        $TrustPrompt = {
            param([string]$Destination)
            [Windows.MessageBox]::Show(
                "Allow this relay script to contact $Destination?",
                'Trust relay destination',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Warning
            ) -eq [Windows.MessageBoxResult]::Yes
        }
    }

    $state = [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        Providers = @()
        DraftId = $null
        TrustedDestination = $null
        Preview = @()
        CanTest = $true
        IsTesting = $false
        Callbacks = $null
        TrustPrompt = $TrustPrompt
        Disposed = $false
        Delegates = [ordered]@{}
    }

    # Capture helper functions explicitly because the WPF event handlers and
    # adapter callbacks run from GetNewClosure() scriptblocks.
    $getField = ${function:Get-RelayManagerField}
    $getTemplateValue = ${function:Get-RelayManagerTemplateValue}
    $testBuiltInDraft = ${function:Test-RelayManagerBuiltInDraft}
    $trustDisplayOrigin = ${function:ConvertTo-RelayTrustDisplayOrigin}

    $updateTestButton = {
        if ($state.Disposed) { return }
        $safe = & $testBuiltInDraft `
            -TemplateType (& $getTemplateValue $state.Controls.TemplateComboBox) `
            -BaseUrl ([string]$state.Controls.BaseUrlTextBox.Text) `
            -Script ([string]$state.Controls.ScriptTextBox.Text)
        $state.Controls.TestButton.IsEnabled = [bool]($state.CanTest -and -not $state.IsTesting -and $safe)
    }.GetNewClosure()

    $invoke = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return $null }
        $callback = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $callback -and $null -ne $callback.Value) {
            return & $callback.Value @Arguments
        }
        return $null
    }.GetNewClosure()

    $textChanged = [Windows.Controls.TextChangedEventHandler]{ param($sender, $args) & $updateTestButton }.GetNewClosure()
    $selectionChanged = [Windows.Controls.SelectionChangedEventHandler]{ param($sender, $args) & $updateTestButton }.GetNewClosure()
    $state.Delegates.TextChanged = $textChanged
    $state.Delegates.TemplateChanged = $selectionChanged
    $controls.BaseUrlTextBox.Add_TextChanged($textChanged)
    $controls.ScriptTextBox.Add_TextChanged($textChanged)
    $controls.TemplateComboBox.Add_SelectionChanged($selectionChanged)

    foreach ($definition in @(
        @{ Control = 'AddButton'; Callback = 'OnAdd'; UsesSelection = $false; HideOnTrue = $false },
        @{ Control = 'EditButton'; Callback = 'OnEdit'; UsesSelection = $true; HideOnTrue = $false },
        @{ Control = 'DuplicateButton'; Callback = 'OnDuplicate'; UsesSelection = $true; HideOnTrue = $false },
        @{ Control = 'DeleteButton'; Callback = 'OnDelete'; UsesSelection = $true; HideOnTrue = $false },
        @{ Control = 'TestButton'; Callback = 'OnTest'; UsesSelection = $false; HideOnTrue = $false },
        @{ Control = 'SaveButton'; Callback = 'OnSave'; UsesSelection = $false; HideOnTrue = $true },
        @{ Control = 'CancelButton'; Callback = 'OnCancel'; UsesSelection = $false; HideOnTrue = $true }
    )) {
        $callbackName = $definition.Callback
        $usesSelection = [bool]$definition.UsesSelection
        $hideOnTrue = [bool]$definition.HideOnTrue
        $handler = [Windows.RoutedEventHandler]{
            param($sender, $args)
            $arguments = @()
            if ($usesSelection) {
                $selected = $state.Controls.ProviderList.SelectedItem
                if ($null -eq $selected) { return }
                $arguments = @([string]$selected.Id)
            }
            $result = & $invoke $callbackName $arguments
            if ($hideOnTrue -and $result -eq $true) { $state.Window.Hide() }
        }.GetNewClosure()
        $state.Delegates[$definition.Control] = $handler
        $controls[$definition.Control].Add_Click($handler)
    }

    $showDialog = {
        if ($state.Disposed) { return $false }
        return $state.Window.ShowDialog()
    }.GetNewClosure()
    $setProviders = {
        param([AllowEmptyCollection()][object[]]$Providers)
        if ($state.Disposed) { return }
        $safe = [Collections.Generic.List[object]]::new()
        foreach ($provider in @($Providers)) {
            $id = [string](& $getField $provider 'Id')
            $name = [string](& $getField $provider 'Name')
            $enabled = [bool](& $getField $provider 'Enabled')
            $safe.Add([pscustomobject][ordered]@{
                Id = $id
                DisplayName = if ($enabled) { $name } else { "$name (disabled)" }
            })
        }
        $state.Providers = [object[]]$safe.ToArray()
        $state.Controls.ProviderList.ItemsSource = $state.Providers
    }.GetNewClosure()
    $readDraft = {
        if ($state.Disposed) { return $null }
        $timeout = 0
        $interval = 0
        $null = [int]::TryParse([string]$state.Controls.TimeoutTextBox.Text, [ref]$timeout)
        $null = [int]::TryParse([string]$state.Controls.IntervalTextBox.Text, [ref]$interval)
        return [pscustomobject][ordered]@{
            Id = [string]$state.DraftId
            Name = [string]$state.Controls.NameTextBox.Text
            Enabled = [bool]$state.Controls.EnabledCheckBox.IsChecked
            BaseUrl = [string]$state.Controls.BaseUrlTextBox.Text
            TemplateType = & $getTemplateValue $state.Controls.TemplateComboBox
            Script = [string]$state.Controls.ScriptTextBox.Text
            TimeoutSeconds = $timeout
            IntervalMinutes = $interval
            TrustedDestination = $state.TrustedDestination
            Secrets = [pscustomobject][ordered]@{
                ApiKey = [string]$state.Controls.ApiKeyPasswordBox.Password
                AccessToken = [string]$state.Controls.AccessTokenPasswordBox.Password
                UserId = [string]$state.Controls.UserIdPasswordBox.Password
            }
        }
    }.GetNewClosure()
    $setDraft = {
        param([AllowNull()][object]$Draft)
        if ($state.Disposed -or $null -eq $Draft) { return }
        $state.DraftId = [string](& $getField $Draft 'Id')
        $state.TrustedDestination = & $getField $Draft 'TrustedDestination'
        $state.Controls.EnabledCheckBox.IsChecked = [bool](& $getField $Draft 'Enabled')
        $state.Controls.NameTextBox.Text = [string](& $getField $Draft 'Name')
        $state.Controls.BaseUrlTextBox.Text = [string](& $getField $Draft 'BaseUrl')
        $template = [string](& $getField $Draft 'TemplateType')
        $state.Controls.TemplateComboBox.SelectedItem = @(
            $state.Controls.TemplateComboBox.Items | Where-Object { [string]$_.Tag -ceq $template }
        )[0]
        $state.Controls.ScriptTextBox.Text = [string](& $getField $Draft 'Script')
        $state.Controls.TimeoutTextBox.Text = [string](& $getField $Draft 'TimeoutSeconds')
        $state.Controls.IntervalTextBox.Text = [string](& $getField $Draft 'IntervalMinutes')
        $state.Controls.ApiKeyPasswordBox.Clear()
        $state.Controls.AccessTokenPasswordBox.Clear()
        $state.Controls.UserIdPasswordBox.Clear()
        $state.Preview = @()
        $state.Controls.PreviewList.ItemsSource = $null
        & $updateTestButton
    }.GetNewClosure()
    $setTestState = {
        param([bool]$CanTest, [bool]$IsTesting, [AllowNull()][string]$Message)
        if ($state.Disposed) { return }
        $state.CanTest = $CanTest
        $state.IsTesting = $IsTesting
        $state.Controls.TestStateText.Text = if ($null -eq $Message) { '' } else { $Message }
        & $updateTestButton
    }.GetNewClosure()
    $setPreview = {
        param([AllowNull()][object]$Preview)
        if ($state.Disposed) { return }
        $safe = [Collections.Generic.List[object]]::new()
        $display = [Collections.Generic.List[string]]::new()
        foreach ($item in @($Preview)) {
            if ($null -eq $item) { continue }
            $category = & $getField $item 'Category'
            if ($null -ne $category) {
                $status = & $getField $item 'HttpStatus'
                $entry = [pscustomobject][ordered]@{
                    Category = [string]$category
                Message = [string](& $getField $item 'Message')
                    HttpStatus = $status
                }
                $safe.Add($entry)
                $statusText = if ($null -eq $status) { '' } else { " ($status)" }
                $display.Add("$($entry.Category)${statusText}: $($entry.Message)")
                continue
            }
            $entry = [pscustomobject][ordered]@{
                IsValid = [bool](Get-RelayManagerField $item 'IsValid')
                InvalidMessage = & $getField $item 'InvalidMessage'
                Remaining = & $getField $item 'Remaining'
                Unit = & $getField $item 'Unit'
                PlanName = & $getField $item 'PlanName'
                Total = & $getField $item 'Total'
                Used = & $getField $item 'Used'
                Extra = & $getField $item 'Extra'
            }
            $safe.Add($entry)
            $label = if ([string]::IsNullOrWhiteSpace([string]$entry.PlanName)) { 'Result' } else { [string]$entry.PlanName }
            $display.Add("${label}: $($entry.Remaining) $($entry.Unit)")
        }
        $state.Preview = [object[]]$safe.ToArray()
        $state.Controls.PreviewList.ItemsSource = [string[]]$display.ToArray()
    }.GetNewClosure()
    $confirmDestinationTrust = {
        param([AllowNull()][string]$Destination)
        if ($state.Disposed) { return $false }
        $displayOrigin = & $trustDisplayOrigin $Destination
        if ($null -eq $displayOrigin) { return $false }
        return [bool](& $state.TrustPrompt $displayOrigin)
    }.GetNewClosure()
    $setCallbacks = {
        param(
            [AllowNull()][scriptblock]$OnAdd,
            [AllowNull()][scriptblock]$OnEdit,
            [AllowNull()][scriptblock]$OnDuplicate,
            [AllowNull()][scriptblock]$OnDelete,
            [AllowNull()][scriptblock]$OnTest,
            [AllowNull()][scriptblock]$OnSave,
            [AllowNull()][scriptblock]$OnCancel
        )
        if ($state.Disposed) { return }
        $state.Callbacks = [pscustomobject][ordered]@{
            OnAdd = $OnAdd; OnEdit = $OnEdit; OnDuplicate = $OnDuplicate; OnDelete = $OnDelete
            OnTest = $OnTest; OnSave = $OnSave; OnCancel = $OnCancel
        }
    }.GetNewClosure()
    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        foreach ($definition in @(
            @{ Control = 'BaseUrlTextBox'; Event = 'TextChanged'; Delegate = 'TextChanged' },
            @{ Control = 'ScriptTextBox'; Event = 'TextChanged'; Delegate = 'TextChanged' },
            @{ Control = 'TemplateComboBox'; Event = 'SelectionChanged'; Delegate = 'TemplateChanged' }
        )) {
            $controls[$definition.Control].("Remove_$($definition.Event)")($state.Delegates[$definition.Delegate])
        }
        foreach ($name in @('AddButton','EditButton','DuplicateButton','DeleteButton','TestButton','SaveButton','CancelButton')) {
            $controls[$name].Remove_Click($state.Delegates[$name])
        }
        $state.Callbacks = $null
        $state.TrustPrompt = $null
        $state.Providers = @()
        $state.Preview = @()
        try { $window.Close() } catch [InvalidOperationException] {}
    }.GetNewClosure()

    $controls.TemplateComboBox.SelectedIndex = 1
    & $updateTestButton
    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        ShowDialog = $showDialog
        SetProviders = $setProviders
        ReadDraft = $readDraft
        SetDraft = $setDraft
        SetTestState = $setTestState
        SetPreview = $setPreview
        ConfirmDestinationTrust = $confirmDestinationTrust
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}

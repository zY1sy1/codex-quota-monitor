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

function Get-RelayManagerComboValue {
    param([Parameter(Mandatory)][Windows.Controls.ComboBox]$ComboBox)
    $item = $ComboBox.SelectedItem
    if ($item -is [Windows.Controls.ComboBoxItem]) { return [string]$item.Tag }
    return [string]$item
}

function ConvertTo-RelayManagerJsonMap {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [ordered]@{} }
    try {
        $parsed = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 8 -ErrorAction Stop
    }
    catch {
        return $null
    }
    if ($parsed -isnot [Collections.IDictionary]) { return $null }
    $result = [ordered]@{}
    foreach ($entry in $parsed.GetEnumerator()) {
        $name = [string]$entry.Key
        if ([string]::IsNullOrWhiteSpace($name) -or $entry.Value -isnot [string]) {
            return $null
        }
        $result[$name] = [string]$entry.Value
    }
    return $result
}

function ConvertTo-RelayManagerJsonText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '{}' }
    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Test-RelayManagerBaseUrl {
    param([AllowNull()][string]$BaseUrl)
    $uri = $null
    return -not [string]::IsNullOrWhiteSpace($BaseUrl) -and
        [Uri]::TryCreate($BaseUrl.Trim(), [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -in @('http', 'https') -and
        -not [string]::IsNullOrEmpty($uri.Host) -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment)
}

function Test-RelayManagerPath {
    param([AllowNull()][string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path.Length -le 4096 -and
        $Path -notmatch '^(?i)(https?:|//)' -and
        $Path -notmatch '[?#\x00-\x1f]'
}

function Test-RelayManagerExtractor {
    param([AllowNull()][string]$Script, [Parameter(Mandatory)][string]$ProviderKind)
    if ([string]::IsNullOrWhiteSpace($Script)) { return $false }
    if ($ProviderKind -ceq 'Custom') { return $true }
    return $Script.Trim() -match '^(?s)(?:async\s+)?function\b|^(?:[A-Za-z_$][A-Za-z0-9_$]*|\([^)]*\))\s*=>'
}

function Test-RelayManagerDraft {
    param(
        [AllowNull()][string]$ProviderKind,
        [AllowNull()][string]$BaseUrl,
        [AllowNull()][string]$Method,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$QueryText,
        [AllowNull()][string]$HeadersText,
        [AllowNull()][string]$ExtractorScript
    )
    if ($ProviderKind -notin @('Generic', 'Custom') -or -not (Test-RelayManagerBaseUrl $BaseUrl) -or
        -not (Test-RelayManagerExtractor $ExtractorScript $ProviderKind)) {
        return $false
    }
    if ($ProviderKind -ceq 'Custom') { return $true }
    if ($Method -notin @('GET', 'POST', 'PUT') -or -not (Test-RelayManagerPath $Path)) {
        return $false
    }
    return $null -ne (ConvertTo-RelayManagerJsonMap $QueryText) -and
        $null -ne (ConvertTo-RelayManagerJsonMap $HeadersText)
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
        [Parameter()][AllowNull()][scriptblock]$TrustPrompt
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
        'EnabledCheckBox', 'NameTextBox', 'ProviderKindComboBox', 'BaseUrlTextBox',
        'AdvancedRequestExpander', 'MethodComboBox', 'PathTextBox', 'QueryTextBox',
        'HeadersTextBox', 'BodyTextBox', 'ExtractorScriptTextBox', 'MigrationWarningText',
        'ApiKeyPasswordBox', 'AccessTokenPasswordBox', 'UserIdPasswordBox',
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
                "Allow this relay provider to contact $Destination?",
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

    $getField = ${function:Get-RelayManagerField}
    $getComboValue = ${function:Get-RelayManagerComboValue}
    $jsonMap = ${function:ConvertTo-RelayManagerJsonMap}
    $jsonText = ${function:ConvertTo-RelayManagerJsonText}
    $validDraft = ${function:Test-RelayManagerDraft}
    $trustDisplayOrigin = ${function:ConvertTo-RelayTrustDisplayOrigin}

    $setGenericControlState = {
        $generic = (& $getComboValue $state.Controls.ProviderKindComboBox) -ceq 'Generic'
        $state.Controls.AdvancedRequestExpander.IsEnabled = $generic
        foreach ($name in @('MethodComboBox', 'PathTextBox', 'QueryTextBox', 'HeadersTextBox', 'BodyTextBox')) {
            $state.Controls[$name].IsEnabled = $generic
        }
    }.GetNewClosure()

    $updateTestButton = {
        if ($state.Disposed) { return }
        & $setGenericControlState
        $state.Controls.TestButton.IsEnabled = [bool]($state.CanTest -and -not $state.IsTesting -and (& $validDraft `
            -ProviderKind (& $getComboValue $state.Controls.ProviderKindComboBox) `
            -BaseUrl ([string]$state.Controls.BaseUrlTextBox.Text) `
            -Method (& $getComboValue $state.Controls.MethodComboBox) `
            -Path ([string]$state.Controls.PathTextBox.Text) `
            -QueryText ([string]$state.Controls.QueryTextBox.Text) `
            -HeadersText ([string]$state.Controls.HeadersTextBox.Text) `
            -ExtractorScript ([string]$state.Controls.ExtractorScriptTextBox.Text)))
    }.GetNewClosure()

    $invoke = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return $null }
        $callback = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $callback -and $null -ne $callback.Value) { return & $callback.Value @Arguments }
        return $null
    }.GetNewClosure()

    $textChanged = [Windows.Controls.TextChangedEventHandler]{ param($sender, $args) & $updateTestButton }.GetNewClosure()
    $selectionChanged = [Windows.Controls.SelectionChangedEventHandler]{ param($sender, $args) & $updateTestButton }.GetNewClosure()
    $state.Delegates.TextChanged = $textChanged
    $state.Delegates.SelectionChanged = $selectionChanged
    foreach ($name in @('BaseUrlTextBox','PathTextBox','QueryTextBox','HeadersTextBox','BodyTextBox','ExtractorScriptTextBox')) {
        $controls[$name].Add_TextChanged($textChanged)
    }
    $controls.ProviderKindComboBox.Add_SelectionChanged($selectionChanged)
    $controls.MethodComboBox.Add_SelectionChanged($selectionChanged)

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

    $showDialog = { if (-not $state.Disposed) { return $state.Window.ShowDialog() } }.GetNewClosure()
    $setProviders = {
        param([AllowEmptyCollection()][object[]]$Providers)
        if ($state.Disposed) { return }
        $safe = [Collections.Generic.List[object]]::new()
        foreach ($provider in @($Providers)) {
            $name = [string](& $getField $provider 'Name')
            $safe.Add([pscustomobject][ordered]@{
                Id = [string](& $getField $provider 'Id')
                DisplayName = if ([bool](& $getField $provider 'Enabled')) { $name } else { "$name (disabled)" }
            })
        }
        $state.Providers = [object[]]$safe.ToArray()
        $state.Controls.ProviderList.ItemsSource = $state.Providers
    }.GetNewClosure()

    $readDraft = {
        if ($state.Disposed) { return $null }
        $timeout = 0; $interval = 0
        $null = [int]::TryParse([string]$state.Controls.TimeoutTextBox.Text, [ref]$timeout)
        $null = [int]::TryParse([string]$state.Controls.IntervalTextBox.Text, [ref]$interval)
        $kind = & $getComboValue $state.Controls.ProviderKindComboBox
        $request = $null
        if ($kind -ceq 'Generic') {
            $request = [pscustomobject][ordered]@{
                Method = & $getComboValue $state.Controls.MethodComboBox
                Path = [string]$state.Controls.PathTextBox.Text
                Query = & $jsonMap ([string]$state.Controls.QueryTextBox.Text)
                Headers = & $jsonMap ([string]$state.Controls.HeadersTextBox.Text)
                Body = if ([string]::IsNullOrEmpty([string]$state.Controls.BodyTextBox.Text)) { $null } else { [string]$state.Controls.BodyTextBox.Text }
            }
        }
        [pscustomobject][ordered]@{
            Id = [string]$state.DraftId
            Name = [string]$state.Controls.NameTextBox.Text
            Enabled = [bool]$state.Controls.EnabledCheckBox.IsChecked
            ProviderKind = $kind
            BaseUrl = [string]$state.Controls.BaseUrlTextBox.Text
            RequestDefinition = $request
            ExtractorScript = [string]$state.Controls.ExtractorScriptTextBox.Text
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
        $kind = [string](& $getField $Draft 'ProviderKind')
        if ($kind -notin @('Generic','Custom')) { $kind = 'Generic' }
        $state.Controls.ProviderKindComboBox.SelectedItem = @(
            $state.Controls.ProviderKindComboBox.Items | Where-Object { [string]$_.Tag -ceq $kind }
        )[0]
        $request = & $getField $Draft 'RequestDefinition'
        $state.Controls.MethodComboBox.SelectedItem = @(
            $state.Controls.MethodComboBox.Items | Where-Object { [string]$_.Tag -ceq [string](& $getField $request 'Method') }
        )[0]
        $state.Controls.PathTextBox.Text = [string](& $getField $request 'Path')
        $state.Controls.QueryTextBox.Text = & $jsonText (& $getField $request 'Query')
        $state.Controls.HeadersTextBox.Text = & $jsonText (& $getField $request 'Headers')
        $body = & $getField $request 'Body'
        $state.Controls.BodyTextBox.Text = if ($null -eq $body) { '' } else { [string]$body }
        $state.Controls.EnabledCheckBox.IsChecked = [bool](& $getField $Draft 'Enabled')
        $state.Controls.NameTextBox.Text = [string](& $getField $Draft 'Name')
        $state.Controls.BaseUrlTextBox.Text = [string](& $getField $Draft 'BaseUrl')
        $state.Controls.ExtractorScriptTextBox.Text = [string](& $getField $Draft 'ExtractorScript')
        $state.Controls.TimeoutTextBox.Text = [string](& $getField $Draft 'TimeoutSeconds')
        $state.Controls.IntervalTextBox.Text = [string](& $getField $Draft 'IntervalMinutes')
        $warning = [string](& $getField $Draft 'MigrationWarning')
        $state.Controls.MigrationWarningText.Text = $warning
        $state.Controls.MigrationWarningText.Visibility = if ([string]::IsNullOrWhiteSpace($warning)) {
            [Windows.Visibility]::Collapsed
        } else { [Windows.Visibility]::Visible }
        $state.Controls.ApiKeyPasswordBox.Clear(); $state.Controls.AccessTokenPasswordBox.Clear(); $state.Controls.UserIdPasswordBox.Clear()
        $state.Preview = @(); $state.Controls.PreviewList.ItemsSource = $null
        & $updateTestButton
    }.GetNewClosure()

    $setTestState = {
        param([bool]$CanTest, [bool]$IsTesting, [AllowNull()][string]$Message)
        if ($state.Disposed) { return }
        $state.CanTest = $CanTest; $state.IsTesting = $IsTesting
        $state.Controls.TestStateText.Text = if ($null -eq $Message) { '' } else { $Message }
        & $updateTestButton
    }.GetNewClosure()

    $setPreview = {
        param([AllowNull()][object]$Preview)
        if ($state.Disposed) { return }
        $safe = [Collections.Generic.List[object]]::new(); $display = [Collections.Generic.List[string]]::new()
        foreach ($item in @($Preview)) {
            if ($null -eq $item) { continue }
            $category = & $getField $item 'Category'
            if ($null -ne $category) {
                $entry = [pscustomobject][ordered]@{
                    Category = [string]$category
                    Message = [string](& $getField $item 'Message')
                    HttpStatus = & $getField $item 'HttpStatus'
                }
                $safe.Add($entry)
                $status = if ($null -eq $entry.HttpStatus) { '' } else { " ($($entry.HttpStatus))" }
                $display.Add("$($entry.Category)${status}: $($entry.Message)")
                continue
            }
            $entry = [pscustomobject][ordered]@{
                IsValid = [bool](& $getField $item 'IsValid')
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
        param($OnAdd, $OnEdit, $OnDuplicate, $OnDelete, $OnTest, $OnSave, $OnCancel)
        if (-not $state.Disposed) {
            $state.Callbacks = [pscustomobject][ordered]@{ OnAdd=$OnAdd; OnEdit=$OnEdit; OnDuplicate=$OnDuplicate; OnDelete=$OnDelete; OnTest=$OnTest; OnSave=$OnSave; OnCancel=$OnCancel }
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        foreach ($name in @('BaseUrlTextBox','PathTextBox','QueryTextBox','HeadersTextBox','BodyTextBox','ExtractorScriptTextBox')) {
            $controls[$name].Remove_TextChanged($state.Delegates.TextChanged)
        }
        $controls.ProviderKindComboBox.Remove_SelectionChanged($state.Delegates.SelectionChanged)
        $controls.MethodComboBox.Remove_SelectionChanged($state.Delegates.SelectionChanged)
        foreach ($name in @('AddButton','EditButton','DuplicateButton','DeleteButton','TestButton','SaveButton','CancelButton')) {
            $controls[$name].Remove_Click($state.Delegates[$name])
        }
        $state.Callbacks = $null; $state.TrustPrompt = $null; $state.Providers = @(); $state.Preview = @()
        try { $window.Close() } catch [InvalidOperationException] {}
    }.GetNewClosure()

    $controls.ProviderKindComboBox.SelectedIndex = 0
    $controls.MethodComboBox.SelectedIndex = 0
    $controls.QueryTextBox.Text = '{}'
    $controls.HeadersTextBox.Text = '{}'
    & $updateTestButton
    return [pscustomobject][ordered]@{
        Window = $window; Controls = $controls; State = $state; ShowDialog = $showDialog
        SetProviders = $setProviders; ReadDraft = $readDraft; SetDraft = $setDraft
        SetTestState = $setTestState; SetPreview = $setPreview; ConfirmDestinationTrust = $confirmDestinationTrust
        SetCallbacks = $setCallbacks; Dispose = $dispose
    }
}

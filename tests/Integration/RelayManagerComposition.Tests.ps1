BeforeAll {
    if ([string]::IsNullOrEmpty($env:windir) -and -not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $env:windir = $env:SystemRoot
    }
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:XamlPath = Join-Path $script:CompanionRoot 'UI\RelayManager.xaml'
    $script:ViewPath = Join-Path $script:CompanionRoot 'Private\RelayManagerView.ps1'
    $script:ControllerPath = Join-Path $script:CompanionRoot 'Private\InteractionController.ps1'
    $script:StorePath = Join-Path $script:CompanionRoot 'Private\RelayProviderStore.ps1'
    $script:CcSwitchImportPath = Join-Path $script:CompanionRoot 'Private\CcSwitchUsageImport.ps1'
    $script:ImportLinkStorePath = Join-Path $script:CompanionRoot 'Private\RelayImportLinkStore.ps1'

    if (Test-Path -LiteralPath $script:StorePath -PathType Leaf) { . $script:StorePath }
    if (Test-Path -LiteralPath $script:CcSwitchImportPath -PathType Leaf) { . $script:CcSwitchImportPath }
    if (Test-Path -LiteralPath $script:ImportLinkStorePath -PathType Leaf) { . $script:ImportLinkStorePath }
    if (Test-Path -LiteralPath $script:ControllerPath -PathType Leaf) { . $script:ControllerPath }
    if (Test-Path -LiteralPath $script:ViewPath -PathType Leaf) { . $script:ViewPath }

    function New-TestRelayDraft {
        param(
            [string]$Id = '11111111-1111-1111-1111-111111111111',
            [string]$ProviderKind = 'Generic',
            [string]$BaseUrl = 'https://relay.example',
            [string]$Method = 'GET',
            [string]$Path = '/usage',
            [AllowNull()][object]$Query = $null,
            [AllowNull()][object]$Headers = $null,
            [AllowNull()][string]$Body = $null,
            [string]$ExtractorScript = 'function(response){return {isValid:true,remaining:response.balance};}',
            [AllowNull()][object]$TrustedDestination = $null
        )
        if ($null -eq $Query) { $Query = [ordered]@{} }
        if ($null -eq $Headers) { $Headers = [ordered]@{} }
        [pscustomobject][ordered]@{
            Id = $Id
            Name = 'Example relay'
            Enabled = $true
            ProviderKind = $ProviderKind
            BaseUrl = $BaseUrl
            RequestDefinition = if ($ProviderKind -eq 'Generic') {
                [pscustomobject][ordered]@{
                    Method = $Method; Path = $Path; Query = [pscustomobject]$Query
                    Headers = [pscustomobject]$Headers; Body = $Body
                }
            } else { $null }
            ExtractorScript = $ExtractorScript
            TimeoutSeconds = 10
            IntervalMinutes = 15
            TrustedDestination = $TrustedDestination
            Secrets = [pscustomobject][ordered]@{
                ApiKey = ''
                AccessToken = ''
                UserId = ''
            }
        }
    }

    function New-TestRelayImportResult {
        $draft = New-TestRelayDraft -Id '22222222-2222-2222-2222-222222222222' `
            -BaseUrl 'https://api.wkkapi.com'
        $draft.Name = 'wakaka'
        [pscustomobject][ordered]@{
            Draft = $draft
            Link = [pscustomobject][ordered]@{
                RelayProviderId = $draft.Id
                SourceKind = 'CcSwitchUsageScript'
                SourceProviderId = 'source-1'
                SourceAppType = 'codex'
                ScriptFingerprint = ('b' * 64)
            }
        }
    }

    function New-FakeRelayManagerView {
        param(
            [object]$InitialDraft = (New-TestRelayDraft),
            [scriptblock]$DialogAction = { param($state) }
        )
        $state = [pscustomobject][ordered]@{
            Draft = $InitialDraft
            Providers = @()
            DraftsSet = [Collections.Generic.List[object]]::new()
            Preview = $null
            TestStates = [Collections.Generic.List[object]]::new()
            TrustPrompts = [Collections.Generic.List[string]]::new()
            TrustAnswer = $false
            Callbacks = $null
            ShowCalls = 0
            Disposed = $false
            DialogAction = $DialogAction
        }
        [pscustomobject][ordered]@{
            TestState = $state
            ShowDialog = {
                $state.ShowCalls++
                & $state.DialogAction $state
                return $false
            }.GetNewClosure()
            SetProviders = { param($Providers) $state.Providers = @($Providers) }.GetNewClosure()
            ReadDraft = { return $state.Draft }.GetNewClosure()
            SetDraft = {
                param($Draft)
                $state.Draft = $Draft
                $state.DraftsSet.Add($Draft)
            }.GetNewClosure()
            SetTestState = {
                param($CanTest, $IsTesting, $Message)
                $state.TestStates.Add([pscustomobject]@{
                    CanTest = $CanTest; IsTesting = $IsTesting; Message = $Message
                })
            }.GetNewClosure()
            SetPreview = { param($Preview) $state.Preview = @($Preview) }.GetNewClosure()
            ConfirmDestinationTrust = {
                param($Destination)
                $state.TrustPrompts.Add([string]$Destination)
                return [bool]$state.TrustAnswer
            }.GetNewClosure()
            SetCallbacks = {
                param($OnAdd, $OnEdit, $OnDuplicate, $OnDelete, $OnImport, $OnTest, $OnSave, $OnCancel)
                $state.Callbacks = [pscustomobject]$PSBoundParameters
            }.GetNewClosure()
            Dispose = { $state.Disposed = $true }.GetNewClosure()
        }
    }
}

Describe 'relay manager WPF adapter contract' {
    BeforeEach {
        $script:View = $null
    }

    AfterEach {
        if ($null -ne $script:View) { & $script:View.Dispose }
    }

    It 'declares every provider-management control with password-only secret inputs' {
        Test-Path -LiteralPath $XamlPath -PathType Leaf | Should -BeTrue
        [xml]$xaml = Get-Content -LiteralPath $XamlPath -Raw
        $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

        foreach ($name in @(
            'ProviderList', 'AddButton', 'EditButton', 'DuplicateButton', 'DeleteButton', 'ImportButton',
            'EnabledCheckBox', 'NameTextBox', 'ProviderKindComboBox', 'BaseUrlTextBox',
            'AdvancedRequestExpander', 'MethodComboBox', 'PathTextBox', 'QueryTextBox',
            'HeadersTextBox', 'BodyTextBox', 'ExtractorScriptTextBox', 'MigrationWarningText',
            'ApiKeyPasswordBox', 'AccessTokenPasswordBox', 'UserIdPasswordBox',
            'TimeoutTextBox', 'IntervalTextBox', 'TestButton', 'SaveButton', 'CancelButton',
            'PreviewList'
        )) {
            $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager) |
                Should -Not -BeNullOrEmpty -Because "the manager requires $name"
        }
        foreach ($name in @('ApiKeyPasswordBox', 'AccessTokenPasswordBox', 'UserIdPasswordBox')) {
            $xaml.SelectSingleNode("//w:PasswordBox[@x:Name='$name']", $manager) |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'localizes fixed interface text while preserving internal tags' {
        $source = Get-Content -LiteralPath $XamlPath -Raw
        [xml]$xaml = $source
        $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')

        foreach ($expected in @(
            'Title="中转站额度管理"', 'AutomationProperties.Name="中转站额度管理器"',
            'Text="中转站列表"', 'Content="新增"', 'Content="编辑"', 'Content="复制"',
            'Content="删除"', 'Content="启用"', 'Text="名称"', 'Text="类型"',
            'Content="通用配置"', 'Content="自定义脚本"', 'Text="基础地址"',
            'Header="高级请求"', 'Text="请求方法"', 'Text="请求路径"',
            'Text="查询参数 JSON"', 'Text="请求头 JSON"', 'Text="请求体（可选字符串）"',
            'Text="提取函数"', 'Text="API 密钥"', 'Text="访问令牌"', 'Text="用户 ID"',
            'Text="超时（秒）"', 'Text="查询间隔（分钟，0 为手动）"',
            'Content="测试中转站"', 'AutomationProperties.Name="脱敏测试预览"',
            'Content="保存"', 'Content="取消"'
        )) {
            $source | Should -Match ([regex]::Escape($expected))
        }

        $displayValues = @(
            [regex]::Matches(
                $source,
                '(?:Title|Text|Content|Header|AutomationProperties\.Name)="([^"]*)"'
            ) | ForEach-Object { $_.Groups[1].Value }
        )
        foreach ($forbidden in @(
            'Relay quota providers', 'Relay quota provider manager', 'Providers',
            'Relay providers', 'Add', 'Edit', 'Duplicate', 'Delete', 'Enabled',
            'Provider enabled', 'Name', 'Provider name', 'Provider kind', 'Generic',
            'Custom', 'Base URL', 'Advanced request', 'Method', 'Request method',
            'Path', 'Request path', 'Query JSON object', 'Request query',
            'Headers JSON object', 'Request headers', 'Body (optional string)',
            'Request body', 'Extractor function', 'Relay extractor script',
            'Migration warning', 'API key', 'Access token', 'User ID',
            'Timeout (seconds)', 'Timeout seconds', 'Interval (minutes, 0 for manual)',
            'Interval minutes', 'Test provider', 'Sanitized test preview', 'Save', 'Cancel'
        )) {
            $displayValues | Should -Not -Contain $forbidden
        }

        $tags = @(
            $xaml.SelectNodes('//w:ComboBoxItem', $manager) |
                ForEach-Object { $_.GetAttribute('Tag') }
        )
        $tags | Should -Be @('Generic', 'Custom', 'GET', 'POST', 'PUT')
    }

    It 'exposes the exact callable adapter contract' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        $callable = @(
            $script:View.PSObject.Properties |
                Where-Object { $_.Value -is [scriptblock] } |
                Select-Object -ExpandProperty Name
        )
        $callable | Should -Be @(
            'ShowDialog', 'SetProviders', 'ReadDraft', 'SetDraft', 'SetTestState',
            'SetPreview', 'ConfirmDestinationTrust', 'SetCallbacks', 'Dispose'
        )
    }

    It 'cancels ordinary closing and keeps the same window reopenable' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        $window = $script:View.Window
        $window.Show()
        $window.Close()

        $window.IsVisible | Should -BeFalse
        $window.IsLoaded | Should -BeTrue

        $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
        $null = $dispatcher.BeginInvoke(
            [Action]{ $window.Hide() },
            [Windows.Threading.DispatcherPriority]::ApplicationIdle
        )
        $null = & $script:View.ShowDialog
        $script:View.State.Disposed | Should -BeFalse
    }

    It 'never copies existing encrypted or plaintext secrets into normal text properties' {
        $cipherSentinel = 'ENCRYPTED_SENTINEL_67291'
        $plainSentinel = 'PLAINTEXT_SENTINEL_98314'
        $provider = New-TestRelayDraft
        $provider.Secrets.ApiKey = $cipherSentinel
        $provider.Secrets.AccessToken = $cipherSentinel
        $provider.Secrets.UserId = $cipherSentinel
        $provider | Add-Member -NotePropertyName PlainTextSecrets -NotePropertyValue $plainSentinel

        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        & $script:View.SetProviders @($provider)
        & $script:View.SetDraft $provider

        $normalText = @(
            $script:View.Controls.Values |
                Where-Object { $_ -is [Windows.Controls.TextBox] -or $_ -is [Windows.Controls.TextBlock] } |
                ForEach-Object { [string]$_.Text }
        ) -join "`n"
        $normalText | Should -Not -Match $cipherSentinel
        $normalText | Should -Not -Match $plainSentinel
        $script:View.Controls.ApiKeyPasswordBox.Password | Should -BeNullOrEmpty
        $script:View.Controls.AccessTokenPasswordBox.Password | Should -BeNullOrEmpty
        $script:View.Controls.UserIdPasswordBox.Password | Should -BeNullOrEmpty
    }

    It 'returns entered secrets only from password boxes to ReadDraft' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        & $script:View.SetDraft (New-TestRelayDraft)
        $script:View.Controls.ApiKeyPasswordBox.Password = 'api-secret'
        $script:View.Controls.AccessTokenPasswordBox.Password = 'token-secret'
        $script:View.Controls.UserIdPasswordBox.Password = 'user-secret'

        $draft = & $script:View.ReadDraft

        $draft.Secrets.ApiKey | Should -BeExactly 'api-secret'
        $draft.Secrets.AccessToken | Should -BeExactly 'token-secret'
        $draft.Secrets.UserId | Should -BeExactly 'user-secret'
        (@($script:View.Controls.Values | Where-Object { $_ -is [Windows.Controls.TextBox] } |
            ForEach-Object Text) -join "`n") | Should -Not -Match 'api-secret|token-secret|user-secret'
    }

    It 'uses manual mode only for an explicit numeric zero interval' -ForEach @(
        @{ Value = ''; Expected = -1 }
        @{ Value = 'abc'; Expected = -1 }
        @{ Value = '5.5'; Expected = -1 }
        @{ Value = '0'; Expected = 0 }
    ) {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        & $script:View.SetDraft (New-TestRelayDraft)
        $script:View.Controls.IntervalTextBox.Text = $Value

        (& $script:View.ReadDraft).IntervalMinutes | Should -Be $Expected
    }

    It 'round-trips import metadata without placing it in a text control' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        $draft = New-TestRelayDraft
        $draft | Add-Member -NotePropertyName ImportLink -NotePropertyValue ([pscustomobject]@{
            RelayProviderId = $draft.Id
            SourceKind = 'CcSwitchUsageScript'
            SourceProviderId = 'hidden-source-59127'
            SourceAppType = 'codex'
            ScriptFingerprint = ('a' * 64)
        })

        & $script:View.SetDraft $draft
        $roundTrip = & $script:View.ReadDraft

        $roundTrip.ImportLink.SourceProviderId | Should -BeExactly 'hidden-source-59127'
        (@($script:View.Controls.Values |
            Where-Object { $_ -is [Windows.Controls.TextBox] -or $_ -is [Windows.Controls.TextBlock] } |
            ForEach-Object { [string]$_.Text }) -join "`n") | Should -Not -Match 'hidden-source-59127'

        & $script:View.SetDraft (New-TestRelayDraft -Id '22222222-2222-2222-2222-222222222222')
        (& $script:View.ReadDraft).ImportLink | Should -BeNullOrEmpty
    }

    It 'disables Test for malformed Generic base URLs and absolute paths' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        & $script:View.SetDraft (New-TestRelayDraft -BaseUrl 'not-a-url')
        $script:View.Controls.TestButton.IsEnabled | Should -BeFalse

        & $script:View.SetDraft (New-TestRelayDraft -Path 'https://other.example/usage')
        $script:View.Controls.TestButton.IsEnabled | Should -BeFalse

        & $script:View.SetDraft (New-TestRelayDraft)
        $script:View.Controls.TestButton.IsEnabled | Should -BeTrue
    }

    It 'allowlists sanitized failures and normalized rows in preview' {
        $secret = 'RAW_PREVIEW_SENTINEL_47123'
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        & $script:View.SetPreview @(
            [pscustomobject]@{
                Category = 'HttpStatus'; Message = 'Relay returned 401.'; HttpStatus = 401
                RawResponse = $secret; RequestHeaders = @{ Authorization = $secret }
            }
        )

        $previewText = @($script:View.Controls.PreviewList.Items | ForEach-Object { [string]$_ }) -join "`n"
        $previewText | Should -Match 'HttpStatus|401'
        $previewText | Should -Not -Match $secret
        ($script:View.State.Preview | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match $secret
    }

    It 'uses Chinese defaults for disabled providers and unnamed results' {
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt { param($value) $false }
        $provider = New-TestRelayDraft
        $provider.Name = '备用站'
        $provider.Enabled = $false

        & $script:View.SetProviders @($provider)
        & $script:View.SetPreview @([pscustomobject]@{
            IsValid = $true
            InvalidMessage = $null
            Remaining = 7
            Unit = 'USD'
            PlanName = $null
            Total = $null
            Used = $null
            Extra = $null
        })

        $script:View.State.Providers[0].DisplayName | Should -BeExactly '备用站（已禁用）'
        [string]$script:View.Controls.PreviewList.Items[0] | Should -BeExactly '结果: 7 USD'
    }

    It 'contains only Chinese fixed relay-manager prompts and status defaults' {
        $viewSource = Get-Content -LiteralPath $ViewPath -Raw
        $controllerSource = Get-Content -LiteralPath $ControllerPath -Raw
        $moduleSource = Get-Content -LiteralPath (Join-Path $CompanionRoot 'CodexQuotaMonitor.psm1') -Raw

        foreach ($expected in @(
            '允许此中转站访问 $Destination 吗？', '信任中转站目标', '（已禁用）', "'结果'"
        )) {
            $viewSource | Should -Match ([regex]::Escape($expected))
        }
        foreach ($forbidden in @(
            'Allow this relay provider to contact', 'Trust relay destination', '(disabled)', "'Result'"
        )) {
            $viewSource | Should -Not -Match ([regex]::Escape($forbidden))
        }

        foreach ($expected in @(
            '中转站设置无效。', '无法保存中转站。', '请重新输入中转站凭据。',
            '正在测试…', '测试成功。', '测试失败。', '中转站脚本主机不可用。'
        )) {
            $controllerSource | Should -Match ([regex]::Escape($expected))
        }
        foreach ($forbidden in @(
            'Provider settings are invalid.', 'Unable to save the relay provider.',
            'Relay credentials must be entered again.', 'Testing...', 'Test succeeded.',
            'Test failed.', 'Relay script host is unavailable.'
        )) {
            $controllerSource | Should -Not -Match ([regex]::Escape($forbidden))
        }

        $moduleSource | Should -Match ([regex]::Escape('确定删除中转站「$name」吗？'))
        $moduleSource | Should -Match ([regex]::Escape("'Codex 额度监视器'"))
        $moduleSource | Should -Match ([regex]::Escape('请重新输入中转站凭据。'))
        $moduleSource | Should -Match ([regex]::Escape('中转站脚本主机不可用。'))
        $moduleSource | Should -Not -Match ([regex]::Escape("Delete relay provider '$name'?"))
        $moduleSource | Should -Not -Match ([regex]::Escape('Relay credentials must be entered again.'))
        $moduleSource | Should -Not -Match ([regex]::Escape('Relay script host is unavailable.'))
    }

    It 'keeps the localized runtime module syntactically valid' {
        $tokens = $null
        $parseErrors = $null
        $modulePath = Join-Path $CompanionRoot 'CodexQuotaMonitor.psm1'

        [Management.Automation.Language.Parser]::ParseFile(
            $modulePath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        @($parseErrors) | Should -BeNullOrEmpty
    }

    It 'shows only a canonical scheme host and port in the trust prompt' {
        $shown = [Collections.Generic.List[string]]::new()
        $script:View = New-RelayManagerView -XamlPath $XamlPath -TrustPrompt {
            param($value) $shown.Add([string]$value); return $false
        }

        & $script:View.ConfirmDestinationTrust 'https://relay.example:443/private?token=secret' |
            Should -BeFalse
        @($shown) | Should -Be @('https://relay.example:443')
    }
}

Describe 'relay manager interaction controller' {
    BeforeEach {
        $script:Existing = New-TestRelayDraft
        $script:Existing.Secrets.ApiKey = 'Y2lwaGVyLWFwaQ=='
        $script:Existing.Secrets.AccessToken = 'Y2lwaGVyLXRva2Vu'
        $script:Existing.Secrets.UserId = 'Y2lwaGVyLXVzZXI='
        $script:View = New-FakeRelayManagerView -InitialDraft (New-TestRelayDraft)
        $script:SavedDocuments = [Collections.Generic.List[object]]::new()
        $script:WriteMutations = [Collections.Generic.List[object]]::new()
        $script:Applied = [Collections.Generic.List[object]]::new()
        $script:Removed = [Collections.Generic.List[string]]::new()
        $script:Queries = [Collections.Generic.List[object]]::new()
        $script:QueryResults = [Collections.Generic.Queue[object]]::new()
        $script:ImportResults = [Collections.Generic.Queue[object]]::new()
        $script:ConfirmDelete = $true
        $script:WriteShouldFail = $false
        $script:Controller = New-RelayManagerController `
            -View $script:View `
            -Providers @($script:Existing) `
            -WriteRelayState {
                param($Document, $Mutation)
                if ($script:WriteShouldFail) { throw 'simulated transaction failure' }
                $script:SavedDocuments.Add($Document)
                $script:WriteMutations.Add($Mutation)
            } `
            -ImportProvider {
                param($Providers)
                if ($script:ImportResults.Count -eq 0) { return $null }
                return $script:ImportResults.Dequeue()
            } `
            -ProtectSecret {
                param($value)
                if ($value) {
                    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("protected:$value"))
                }
                else { '' }
            } `
            -UnprotectSecret {
                param($value)
                if ($value) { 'plain-secret' } else { '' }
            } `
            -QueryProvider {
                param($Provider, $Secrets)
                $script:Queries.Add([pscustomobject]@{ Provider = $Provider; Secrets = $Secrets })
                return $script:QueryResults.Dequeue()
            } `
            -ApplyProviders { param($Providers, $ChangedProviderIds) $script:Applied.Add([pscustomobject]@{ Providers = @($Providers); Changed = @($ChangedProviderIds) }) } `
            -RemoveProviderArtifacts { param($ProviderId) $script:Removed.Add([string]$ProviderId) } `
            -ConfirmDelete { param($Provider) return $script:ConfirmDelete }
    }

    AfterEach {
        if ($null -ne $script:Controller) { & $script:Controller.Dispose }
    }

    It 'starts every new provider with a five-minute interval' {
        & $script:View.TestState.Callbacks.OnAdd

        $script:View.TestState.Draft.IntervalMinutes | Should -Be 5
    }

    It 'duplicates with a new GUID, no trust, and blank encrypted secrets after Save' {
        & $script:View.TestState.Callbacks.OnDuplicate $script:Existing.Id
        $duplicate = $script:View.TestState.Draft
        $duplicate.Id | Should -Not -BeExactly $script:Existing.Id
        [guid]$duplicate.Id | Should -Not -Be ([guid]::Empty)
        $duplicate.TrustedDestination | Should -BeNullOrEmpty
        & $script:View.TestState.Callbacks.OnSave

        $saved = @($script:SavedDocuments[0].Providers | Where-Object Id -eq $duplicate.Id)[0]
        $saved.Secrets.ApiKey | Should -BeExactly ''
        $saved.Secrets.AccessToken | Should -BeExactly ''
        $saved.Secrets.UserId | Should -BeExactly ''
    }

    It 'ignores a reentrant open while the relay manager is already showing' {
        $script:InnerShow = 'unset'
        $script:InnerCalled = $false
        $script:Controller = $null
        $view = New-FakeRelayManagerView -DialogAction {
            param($state)
            if (-not $script:InnerCalled) {
                $script:InnerCalled = $true
                $script:InnerShow = & $script:Controller.Show
            }
            & $state.Callbacks.OnCancel
        }
        $script:Controller = New-RelayManagerController `
            -View $view -Providers @() `
            -WriteRelayState { param($Document, $Mutation) } `
            -ImportProvider { param($Providers) $null } `
            -ProtectSecret { param($Value) $Value } `
            -UnprotectSecret { param($Value) $Value } `
            -QueryProvider { param($Provider, $Secrets) $null } `
            -ApplyProviders { param($Providers, $ChangedProviderIds) } `
            -RemoveProviderArtifacts { param($ProviderId) } `
            -ConfirmDelete { param($Provider) $true }

        $null = & $script:Controller.Show

        $view.TestState.ShowCalls | Should -Be 1
        $script:InnerShow | Should -BeNullOrEmpty
    }

    It 'preserves existing encrypted secrets when password boxes stay blank' {
        & $script:View.TestState.Callbacks.OnEdit $script:Existing.Id
        $script:View.TestState.Draft.Secrets = [pscustomobject]@{ ApiKey = ''; AccessToken = ''; UserId = '' }
        & $script:View.TestState.Callbacks.OnSave

        $saved = @($script:SavedDocuments[0].Providers)[0]
        $saved.Secrets.ApiKey | Should -BeExactly 'Y2lwaGVyLWFwaQ=='
        $saved.Secrets.AccessToken | Should -BeExactly 'Y2lwaGVyLXRva2Vu'
        $saved.Secrets.UserId | Should -BeExactly 'Y2lwaGVyLXVzZXI='
    }

    It 'deletes only after confirmation and removes matching runtime artifacts' {
        $script:ConfirmDelete = $false
        & $script:View.TestState.Callbacks.OnDelete $script:Existing.Id
        $script:SavedDocuments.Count | Should -Be 0
        $script:Removed.Count | Should -Be 0

        $script:ConfirmDelete = $true
        & $script:View.TestState.Callbacks.OnDelete $script:Existing.Id
        @($script:SavedDocuments[0].Providers).Count | Should -Be 0
        @($script:Removed) | Should -Be @($script:Existing.Id)
    }

    It 'declines custom trust without changing trust or explicitly retrying' {
        $draft = New-TestRelayDraft -ProviderKind Custom -TrustedDestination $null `
            -ExtractorScript '({request:{url:"https://new.example/private"},extractor:r=>r})'
        $script:View.TestState.Draft = $draft
        $script:View.TestState.TrustAnswer = $false
        $script:QueryResults.Enqueue([pscustomobject]@{
            Ok = $false
            Error = [pscustomobject]@{
                Category = 'DestinationTrustRequired'
                Message = 'Relay request destination requires explicit trust.'
                HttpStatus = $null
                DestinationHost = 'new.example'
                DestinationFingerprint = 'https://new.example:443'
            }
        })

        & $script:View.TestState.Callbacks.OnTest

        $script:Queries.Count | Should -Be 1
        $script:View.TestState.Draft.TrustedDestination | Should -BeNullOrEmpty
        @($script:View.TestState.TrustPrompts) | Should -Be @('https://new.example:443')
        $script:SavedDocuments.Count | Should -Be 0
    }

    It 'accepts the exact fingerprint and explicitly retries once with it' {
        $draft = New-TestRelayDraft -ProviderKind Custom -TrustedDestination 'https://old.example:443' `
            -ExtractorScript '({request:{url:"https://new.example/private"},extractor:r=>r})'
        $script:View.TestState.Draft = $draft
        $script:View.TestState.TrustAnswer = $true
        $script:QueryResults.Enqueue([pscustomobject]@{
            Ok = $false
            Error = [pscustomobject]@{
                Category = 'DestinationTrustRequired'
                Message = 'Relay request destination requires explicit trust.'
                HttpStatus = $null
                DestinationHost = 'new.example'
                DestinationFingerprint = 'https://new.example:443'
            }
        })
        $script:QueryResults.Enqueue([pscustomobject]@{
            Ok = $true
            Results = @([pscustomobject]@{
                IsValid = $true; InvalidMessage = $null; Remaining = 7; Unit = 'USD'
                PlanName = 'Wallet'; Total = $null; Used = $null; Extra = $null
            })
        })

        & $script:View.TestState.Callbacks.OnTest

        $script:Queries.Count | Should -Be 2
        $script:Queries[0].Provider.TrustedDestination | Should -BeExactly 'https://old.example:443'
        $script:Queries[1].Provider.TrustedDestination | Should -BeExactly 'https://new.example:443'
        $script:View.TestState.Draft.TrustedDestination | Should -BeExactly 'https://new.example:443'
        $script:SavedDocuments.Count | Should -Be 0
        ($script:View.TestState.Preview | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match 'RawResponse|RequestHeaders|DestinationFingerprint'
    }

    It 'requires a current successful test before saving an imported provider and mutates its link' {
        $script:ImportResults.Enqueue((New-TestRelayImportResult))
        $script:QueryResults.Enqueue([pscustomobject]@{
            Ok = $true
            Results = @([pscustomobject]@{
                IsValid = $true; InvalidMessage = $null; Remaining = 8; Unit = 'USD'
                PlanName = 'Wallet'; Total = $null; Used = $null; Extra = $null
            })
        })

        & $script:View.TestState.Callbacks.OnImport
        $script:View.TestState.Draft.Name | Should -BeExactly 'wakaka'
        $script:View.TestState.Draft.ImportLink.SourceProviderId | Should -BeExactly 'source-1'

        (& $script:View.TestState.Callbacks.OnSave) | Should -BeFalse
        $script:View.TestState.TestStates[-1].Message |
            Should -BeExactly '导入的中转站必须通过当前配置测试后才能保存。'

        & $script:View.TestState.Callbacks.OnTest
        (& $script:View.TestState.Callbacks.OnSave) | Should -BeTrue
        $script:WriteMutations[-1].Kind | Should -BeExactly 'Upsert'
        $script:WriteMutations[-1].Link.SourceProviderId | Should -BeExactly 'source-1'

        & $script:View.TestState.Callbacks.OnDelete $script:View.TestState.Draft.Id
        $script:WriteMutations[-1].Kind | Should -BeExactly 'Remove'
        $script:WriteMutations[-1].ProviderId | Should -BeExactly $script:View.TestState.Draft.Id
    }

    It 'invalidates an imported provider test when its BaseUrl changes' {
        $script:ImportResults.Enqueue((New-TestRelayImportResult))
        foreach ($remaining in @(8, 7)) {
            $script:QueryResults.Enqueue([pscustomobject]@{
                Ok = $true
                Results = @([pscustomobject]@{
                    IsValid = $true; InvalidMessage = $null; Remaining = $remaining; Unit = 'USD'
                    PlanName = 'Wallet'; Total = $null; Used = $null; Extra = $null
                })
            })
        }

        & $script:View.TestState.Callbacks.OnImport
        & $script:View.TestState.Callbacks.OnTest
        $script:View.TestState.Draft.BaseUrl = 'https://changed.example'

        (& $script:View.TestState.Callbacks.OnSave) | Should -BeFalse
        $script:SavedDocuments.Count | Should -Be 0
        $script:View.TestState.TestStates[-1].Message |
            Should -BeExactly '导入的中转站必须通过当前配置测试后才能保存。'

        & $script:View.TestState.Callbacks.OnTest
        (& $script:View.TestState.Callbacks.OnSave) | Should -BeTrue
        $script:SavedDocuments.Count | Should -Be 1
    }

    It 'does not mutate controller or runtime state when the relay transaction fails' {
        $script:View.TestState.Draft = New-TestRelayDraft -Id '33333333-3333-3333-3333-333333333333'
        $script:WriteShouldFail = $true

        (& $script:View.TestState.Callbacks.OnSave) | Should -BeFalse

        $script:Applied.Count | Should -Be 0
        @($script:Controller.State.Providers).Count | Should -Be 1
        $script:Controller.State.Providers[0].Id | Should -BeExactly $script:Existing.Id
    }

    It 'preserves ordered Generic query and header entries when copying a draft' {
        $provider = New-TestRelayDraft
        $provider.RequestDefinition.Query = [ordered]@{ account = 'primary' }
        $provider.RequestDefinition.Headers = [ordered]@{ Authorization = 'Bearer {{apiKey}}' }

        $copy = Copy-RelayManagerDraft -Provider $provider

        $copy.RequestDefinition.Query.account | Should -BeExactly 'primary'
        $copy.RequestDefinition.Headers.Authorization | Should -BeExactly 'Bearer {{apiKey}}'
    }

    It 'does not apply scheduler definitions unless Save succeeds' {
        $script:View.TestState.Draft.Secrets.ApiKey = 'new-api-key'
        $script:QueryResults.Enqueue([pscustomobject]@{ Ok = $true; Results = @([pscustomobject]@{
            IsValid = $true; InvalidMessage = $null; Remaining = 1; Unit = $null
            PlanName = $null; Total = $null; Used = $null; Extra = $null
        }) })

        & $script:View.TestState.Callbacks.OnTest
        $script:Applied.Count | Should -Be 0

        & $script:View.TestState.Callbacks.OnSave
        $script:Applied.Count | Should -Be 1
    }

    It 'publishes Chinese validation and test lifecycle states' {
        $script:View.TestState.Draft.BaseUrl = 'not-a-url'
        & $script:View.TestState.Callbacks.OnSave
        $script:View.TestState.TestStates[-1].Message | Should -BeExactly '中转站设置无效。'

        $script:View.TestState.Draft = New-TestRelayDraft
        $script:QueryResults.Enqueue([pscustomobject]@{
            Ok = $true
            Results = @([pscustomobject]@{
                IsValid = $true; InvalidMessage = $null; Remaining = 1; Unit = 'USD'
                PlanName = $null; Total = $null; Used = $null; Extra = $null
            })
        })
        & $script:View.TestState.Callbacks.OnTest

        @($script:View.TestState.TestStates.Message) | Should -Contain '正在测试…'
        $script:View.TestState.TestStates[-1].Message | Should -BeExactly '测试成功。'

        & $script:View.TestState.Callbacks.OnTest
        $script:View.TestState.Preview[0].Message | Should -BeExactly '中转站脚本主机不可用。'
        $script:View.TestState.TestStates[-1].Message | Should -BeExactly '测试失败。'
    }
}

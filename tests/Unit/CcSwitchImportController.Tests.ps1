BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayProviderStore.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\CcSwitchUsageImport.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\CcSwitchImportController.ps1')

    function New-TestImportDescriptor {
        param(
            [string]$Id = 'source-1',
            [string]$Name = 'wakaka',
            [string[]]$Endpoints = @('https://api.wkkapi.com'),
            [string]$Code = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET"},extractor:r=>r})',
            [string]$Status = 'Ready'
        )
        [pscustomobject][ordered]@{
            SourceProviderId = $Id
            SourceAppType = 'codex'
            Name = $Name
            EndpointCandidates = [string[]]$Endpoints
            Language = 'javascript'
            Code = if ($Status -ceq 'Ready') { $Code } else { $null }
            TimeoutSeconds = 10
            TemplateType = 'general'
            AutoQueryIntervalMinutes = 10
            ImportStatus = $Status
        }
    }

    function New-TestDiscoveryResponse {
        param([object[]]$Providers = @((New-TestImportDescriptor)))
        [pscustomobject][ordered]@{ Ok=$true; Providers=[object[]]$Providers; Error=$null }
    }

    function New-TestLinkDocument {
        param([object[]]$Links = @())
        [pscustomobject][ordered]@{ SchemaVersion=1; Links=[object[]]$Links }
    }

    function New-TestExistingProvider {
        [pscustomobject][ordered]@{
            Id = '11111111-1111-1111-1111-111111111111'
            Name = 'Existing relay'
            Enabled = $true
            ProviderKind = 'Generic'
            BaseUrl = 'https://api.wkkapi.com'
            RequestDefinition = $null
            ExtractorScript = 'r=>r'
            TimeoutSeconds = 10
            IntervalMinutes = 30
            TrustedDestination = 'https://api.wkkapi.com:443'
            Secrets = [pscustomobject]@{ ApiKey=''; AccessToken=''; UserId='' }
        }
    }

    function New-FakeCcSwitchImportView {
        param([scriptblock]$DialogAction = { param($State) & $State.Callbacks.OnCancel })
        $state = [pscustomobject][ordered]@{
            Callbacks = $null
            Sources = @()
            Details = $null
            Selection = $null
            BusyStates = [Collections.Generic.List[bool]]::new()
            Statuses = [Collections.Generic.List[string]]::new()
            ConfirmAnswer = $false
            ConfirmCalls = 0
            DialogAction = $DialogAction
            ShowCalls = 0
            Disposed = $false
        }
        [pscustomobject][ordered]@{
            TestState = $state
            ShowDialog = {
                $state.ShowCalls++
                & $state.DialogAction $state
                return $false
            }.GetNewClosure()
            SetSources = { param($Sources) $state.Sources = @($Sources) }.GetNewClosure()
            GetSelection = { return $state.Selection }.GetNewClosure()
            SetSelectionDetails = { param($Details) $state.Details = $Details }.GetNewClosure()
            SetBusy = { param($Busy) $state.BusyStates.Add([bool]$Busy) }.GetNewClosure()
            SetStatus = { param($Message) $state.Statuses.Add([string]$Message) }.GetNewClosure()
            ConfirmCustomImport = {
                param($DisplayName)
                $state.ConfirmCalls++
                return [bool]$state.ConfirmAnswer
            }.GetNewClosure()
            SetCallbacks = {
                param($OnRefresh, $OnSelectionChanged, $OnImport, $OnCancel)
                $state.Callbacks = [pscustomobject][ordered]@{
                    OnRefresh=$OnRefresh
                    OnSelectionChanged=$OnSelectionChanged
                    OnImport=$OnImport
                    OnCancel=$OnCancel
                }
            }.GetNewClosure()
            Dispose = { $state.Disposed = $true }.GetNewClosure()
        }
    }
}

Describe 'CC Switch import controller' {
    It 'ignores a reentrant open while the dialog is already showing' {
        $script:Controller = $null
        $script:InnerShowResult = 'unset'
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $script:InnerShowResult = & $script:Controller.Show -Providers @()
            & $state.Callbacks.OnCancel
        }
        $script:Controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $result = & $script:Controller.Show -Providers @()

        $view.TestState.ShowCalls | Should -Be 1
        $script:InnerShowResult | Should -BeNullOrEmpty
        $result | Should -BeNullOrEmpty
    }

    It 'ignores a reentrant refresh while discovery is already running' {
        $script:DiscoverCalls = 0
        $view = New-FakeCcSwitchImportView
        $controller = $null
        $controller = New-CcSwitchImportController -View $view `
            -Discover {
                $script:DiscoverCalls++
                if ($script:DiscoverCalls -eq 1) {
                    & $view.TestState.Callbacks.OnRefresh | Out-Null
                }
                New-TestDiscoveryResponse
            } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $null = & $controller.Show -Providers @()

        $script:DiscoverCalls | Should -Be 1
    }

    It 'discovers only when the dialog opens or Refresh is invoked' {
        $script:DiscoverCalls = 0
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Copy'
            }
            & $state.Callbacks.OnSelectionChanged
            & $state.Callbacks.OnSelectionChanged
            & $state.Callbacks.OnRefresh
            & $state.Callbacks.OnCancel
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { $script:DiscoverCalls++; New-TestDiscoveryResponse } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $null = & $controller.Show -Providers @()

        $script:DiscoverCalls | Should -Be 2
        @($view.TestState.BusyStates) | Should -Be @($true, $false, $true, $false)
    }

    It 'never exposes raw script code to view state' {
        $sentinel = 'RAW_SCRIPT_SENTINEL_73019'
        $descriptor = New-TestImportDescriptor -Code "({request:{url:'{{baseUrl}}/v1/usage',method:'GET'},extractor:r=>'$sentinel'})"
        $script:DescriptorUnderTest = $descriptor
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Copy'
            }
            & $state.Callbacks.OnSelectionChanged
            & $state.Callbacks.OnCancel
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse -Providers @($script:DescriptorUnderTest) } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $null = & $controller.Show -Providers @()

        ($view.TestState.Sources | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match $sentinel
        ($view.TestState.Details | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match $sentinel
        ($view.TestState.Sources[0].PSObject.Properties.Name -join ',') |
            Should -BeExactly 'SourceProviderId,SourceAppType,DisplayName,ImportStatus,EndpointCandidates'
    }

    It 'disables blocked rows and never calls conversion' {
        $script:ConvertCalls = 0
        $descriptor = New-TestImportDescriptor -Status CredentialDetected
        $script:DescriptorUnderTest = $descriptor
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Copy'
            }
            & $state.Callbacks.OnSelectionChanged
            (& $state.Callbacks.OnImport) | Should -BeFalse
            & $state.Callbacks.OnCancel
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse -Providers @($script:DescriptorUnderTest) } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate { $script:ConvertCalls++; throw 'must not run' }

        $result = & $controller.Show -Providers @()

        $result | Should -BeNullOrEmpty
        $view.TestState.Details.CanImport | Should -BeFalse
        $script:ConvertCalls | Should -Be 0
    }

    It 'preselects one endpoint, requires a choice for many, and permits entry for none' {
        $descriptors = @(
            (New-TestImportDescriptor -Id one -Endpoints @('https://one.example')),
            (New-TestImportDescriptor -Id many -Endpoints @('https://a.example','https://b.example')),
            (New-TestImportDescriptor -Id none -Endpoints @())
        )
        $script:DescriptorsUnderTest = $descriptors
        $script:Observed = [Collections.Generic.List[object]]::new()
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            foreach ($id in @('one','many','none')) {
                $state.Selection = [pscustomobject]@{
                    SourceProviderId=$id; SourceAppType='codex'; Endpoint=''
                    ImportMode='Auto'; Action='Copy'
                }
                & $state.Callbacks.OnSelectionChanged
                $script:Observed.Add($state.Details)
            }
            & $state.Callbacks.OnCancel
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse -Providers $script:DescriptorsUnderTest } `
            -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $null = & $controller.Show -Providers @()

        $script:Observed[0].SelectedEndpoint | Should -BeExactly 'https://one.example'
        $script:Observed[1].SelectedEndpoint | Should -BeNullOrEmpty
        $script:Observed[1].RequiresEndpointSelection | Should -BeTrue
        $script:Observed[2].AllowEndpointEntry | Should -BeTrue
    }

    It 'defaults a linked source to Update and preserves the existing provider identity' {
        $existing = New-TestExistingProvider
        $link = [pscustomobject]@{
            RelayProviderId=$existing.Id; SourceKind='CcSwitchUsageScript'
            SourceProviderId='source-1'; SourceAppType='codex'; ScriptFingerprint=('a' * 64)
        }
        $script:LinkUnderTest = $link
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Update'
            }
            & $state.Callbacks.OnSelectionChanged
            (& $state.Callbacks.OnImport) | Should -BeTrue
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse } `
            -ReadLinks { New-TestLinkDocument -Links @($script:LinkUnderTest) } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $result = & $controller.Show -Providers @($existing)

        $view.TestState.Details.DefaultAction | Should -BeExactly 'Update'
        $result.Draft.Id | Should -BeExactly $existing.Id
        $result.Draft.Name | Should -BeExactly 'Existing relay'
    }

    It 'defaults an unlinked source to Copy' {
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Copy'
            }
            & $state.Callbacks.OnSelectionChanged
            (& $state.Callbacks.OnImport) | Should -BeTrue
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse } -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $result = & $controller.Show -Providers @()

        $view.TestState.Details.DefaultAction | Should -BeExactly 'Copy'
        $result.Draft.Id | Should -Match '^[0-9a-f-]{36}$'
    }

    It 'runs Custom conversion only after explicit confirmation' {
        $script:Modes = [Collections.Generic.List[string]]::new()
        $view = New-FakeCcSwitchImportView -DialogAction {
            param($state)
            $state.Selection = [pscustomobject]@{
                SourceProviderId='source-1'; SourceAppType='codex'
                Endpoint='https://api.wkkapi.com'; ImportMode='Auto'; Action='Copy'
            }
            & $state.Callbacks.OnSelectionChanged
            (& $state.Callbacks.OnImport) | Should -BeFalse
            $state.ConfirmAnswer = $true
            (& $state.Callbacks.OnImport) | Should -BeTrue
        }
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse } -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate {
                param($Descriptor, $Endpoint, $ImportMode, $ExistingProvider)
                $script:Modes.Add([string]$ImportMode)
                if ($ImportMode -eq 'Auto') {
                    return [pscustomobject]@{ Status='RequiresCustom'; Draft=$null; Link=$null }
                }
                return [pscustomobject]@{
                    Status='Ready'; Draft=[pscustomobject]@{ ProviderKind='Custom' }
                    Link=[pscustomobject]@{ SourceProviderId='source-1' }
                }
            }

        $result = & $controller.Show -Providers @()

        @($script:Modes) | Should -Be @('Auto','Auto','Custom')
        $view.TestState.ConfirmCalls | Should -Be 2
        $result.Draft.ProviderKind | Should -BeExactly 'Custom'
    }

    It 'returns null on cancel and detaches callbacks on dispose' {
        $view = New-FakeCcSwitchImportView
        $controller = New-CcSwitchImportController -View $view `
            -Discover { New-TestDiscoveryResponse } -ReadLinks { New-TestLinkDocument } `
            -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

        $result = & $controller.Show -Providers @()
        & $controller.Dispose

        $result | Should -BeNullOrEmpty
        $view.TestState.Callbacks.OnRefresh | Should -BeNullOrEmpty
        $view.TestState.Callbacks.OnImport | Should -BeNullOrEmpty
    }
}

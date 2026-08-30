BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayProviderStore.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\CcSwitchUsageImport.ps1')

    function New-TestCcSwitchDiscoveryProvider {
        [pscustomobject][ordered]@{
            sourceProviderId = 'source-1'
            sourceAppType = 'codex'
            name = 'wakaka'
            endpointCandidates = @('https://api.wkkapi.com')
            language = 'javascript'
            code = "({request:{url:'{{baseUrl}}/v1/usage',method:'GET'},extractor:r=>({isValid:true,remaining:r.balance})})"
            timeoutSeconds = 10
            templateType = 'general'
            autoQueryIntervalMinutes = 10
            importStatus = 'ready'
        }
    }

    function New-TestCcSwitchDiscoveryResponse {
        [pscustomobject][ordered]@{
            ok = $true
            providers = @((New-TestCcSwitchDiscoveryProvider))
            error = $null
        }
    }

    function New-TestCcSwitchTemplateOnlyProvider {
        [pscustomobject][ordered]@{
            sourceProviderId = 'deepseek-builtin'
            sourceAppType = 'codex'
            name = 'DeepSeek'
            endpointCandidates = @('https://api.deepseek.com')
            language = 'javascript'
            code = $null
            timeoutSeconds = 10
            templateType = 'balance'
            autoQueryIntervalMinutes = 5
            importStatus = 'templateOnly'
        }
    }

    function New-TestCcSwitchDescriptor {
        param(
            [string]$Code = "({request:{url:'{{baseUrl}}/v1/usage',method:'GET'},extractor:r=>r})",
            [string[]]$EndpointCandidates = @('https://api.wkkapi.com'),
            [int]$TimeoutSeconds = 10,
            [int]$IntervalMinutes = 10,
            [string]$ImportStatus = 'Ready'
        )
        [pscustomobject][ordered]@{
            SourceProviderId = 'source-1'
            SourceAppType = 'codex'
            Name = 'wakaka'
            EndpointCandidates = [string[]]$EndpointCandidates
            Language = 'javascript'
            Code = if ($ImportStatus -ceq 'Ready') { $Code } else { $null }
            TimeoutSeconds = $TimeoutSeconds
            TemplateType = 'general'
            AutoQueryIntervalMinutes = $IntervalMinutes
            ImportStatus = $ImportStatus
        }
    }
}

Describe 'CC Switch usage discovery client' {
    It 'accepts only the exact sanitized discovery shape' {
        $response = ConvertTo-CcSwitchDiscoveryResponse (New-TestCcSwitchDiscoveryResponse)

        ($response.PSObject.Properties.Name -join ',') | Should -BeExactly 'Ok,Providers,Error'
        ($response.Providers[0].PSObject.Properties.Name -join ',') |
            Should -BeExactly 'SourceProviderId,SourceAppType,Name,EndpointCandidates,Language,Code,TimeoutSeconds,TemplateType,AutoQueryIntervalMinutes,ImportStatus'
        $response.Ok | Should -BeTrue
        $response.Providers[0].Name | Should -BeExactly 'wakaka'
        $response.Providers[0].Code | Should -Match '/v1/usage'
        $response.Providers[0].ImportStatus | Should -BeExactly 'Ready'
    }

    It 'accepts a precise sanitized failure response' {
        $response = ConvertTo-CcSwitchDiscoveryResponse ([pscustomobject][ordered]@{
            ok = $false
            providers = @()
            error = [pscustomobject][ordered]@{
                category = 'CcSwitchNotFound'
                message = 'CC Switch database was not found.'
            }
        })

        $response.Ok | Should -BeFalse
        $response.Providers | Should -HaveCount 0
        ($response.Error.PSObject.Properties.Name -join ',') | Should -BeExactly 'Category,Message'
        $response.Error.Category | Should -BeExactly 'CcSwitchNotFound'
    }

    It 'skips ready providers with an empty script and keeps usable rules' {
        $raw = New-TestCcSwitchDiscoveryResponse
        $raw.providers = @(
            [pscustomobject][ordered]@{
                sourceProviderId = 'empty-script'
                sourceAppType = 'codex'
                name = 'DeepSeek'
                endpointCandidates = @('https://api.deepseek.com')
                language = 'javascript'
                code = ''
                timeoutSeconds = 10
                templateType = 'balance'
                autoQueryIntervalMinutes = 5
                importStatus = 'ready'
            }
            (New-TestCcSwitchDiscoveryProvider)
        )

        $response = ConvertTo-CcSwitchDiscoveryResponse $raw

        $response.Ok | Should -BeTrue
        $response.Providers | Should -HaveCount 1
        $response.Providers[0].Name | Should -BeExactly 'wakaka'
    }

    It 'maps the known DeepSeek built-in balance template to a ready rule' {
        $raw = New-TestCcSwitchDiscoveryResponse
        $raw.providers = @(New-TestCcSwitchTemplateOnlyProvider)

        $response = ConvertTo-CcSwitchDiscoveryResponse $raw

        $response.Providers[0].ImportStatus | Should -BeExactly 'Ready'
        $response.Providers[0].Code | Should -Match '/user/balance'
        $response.Providers[0].Code | Should -Match 'Bearer \{\{apiKey\}\}'
    }

    It 'keeps unknown built-in templates blocked' {
        $provider = New-TestCcSwitchTemplateOnlyProvider
        $provider.endpointCandidates = @('https://relay.example')
        $raw = New-TestCcSwitchDiscoveryResponse
        $raw.providers = @($provider)

        $response = ConvertTo-CcSwitchDiscoveryResponse $raw

        $response.Providers[0].ImportStatus | Should -BeExactly 'TemplateOnly'
        $response.Providers[0].Code | Should -BeNullOrEmpty
    }

    It 'rejects blocked descriptors that unexpectedly contain code' {
        $raw = New-TestCcSwitchDiscoveryResponse
        $raw.providers[0].importStatus = 'credentialDetected'
        $raw.providers[0].code = 'secret text'

        { ConvertTo-CcSwitchDiscoveryResponse $raw } |
            Should -Throw 'CC Switch discovery response is invalid.'
    }

    It 'rejects malformed or expanded response shapes' -ForEach @(
        @{
            Name = 'unknown root field'
            Mutate = { param($raw) $raw | Add-Member -NotePropertyName future -NotePropertyValue $true }
        }
        @{
            Name = 'missing root field'
            Mutate = { param($raw) $raw.PSObject.Properties.Remove('error') }
        }
        @{
            Name = 'unknown provider field'
            Mutate = { param($raw) $raw.providers[0] | Add-Member -NotePropertyName apiKey -NotePropertyValue 'secret' }
        }
        @{
            Name = 'endpoint with credentials'
            Mutate = { param($raw) $raw.providers[0].endpointCandidates = @('https://name:password@relay.example') }
        }
        @{
            Name = 'endpoint with query'
            Mutate = { param($raw) $raw.providers[0].endpointCandidates = @('https://relay.example?token=value') }
        }
        @{
            Name = 'timeout outside range'
            Mutate = { param($raw) $raw.providers[0].timeoutSeconds = 31 }
        }
        @{
            Name = 'interval is not an integer'
            Mutate = { param($raw) $raw.providers[0].autoQueryIntervalMinutes = 1.5 }
        }
        @{
            Name = 'ready descriptor without code'
            Mutate = { param($raw) $raw.providers[0].code = $null }
        }
        @{
            Name = 'unsupported language with code'
            Mutate = { param($raw) $raw.providers[0].language = 'python'; $raw.providers[0].importStatus = 'unsupportedLanguage' }
        }
        @{
            Name = 'unknown import status'
            Mutate = { param($raw) $raw.providers[0].importStatus = 'futureStatus'; $raw.providers[0].code = $null }
        }
        @{
            Name = 'failure with providers'
            Mutate = { param($raw) $raw.ok = $false; $raw.error = [pscustomobject]@{ category='CcSwitchNotFound'; message='missing' } }
        }
    ) {
        $raw = New-TestCcSwitchDiscoveryResponse
        & $Mutate $raw

        { ConvertTo-CcSwitchDiscoveryResponse $raw } |
            Should -Throw 'CC Switch discovery response is invalid.'
    }

    It 'resolves the default database below the supplied profile without touching it' {
        $profile = Join-Path $TestDrive 'profile'

        $path = Get-DefaultCcSwitchDatabasePath -UserProfile $profile

        $path | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $profile '.cc-switch\cc-switch.db')))
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'returns a sanitized failure when the inspector cannot start' {
        $missingExecutable = Join-Path $TestDrive 'missing-relay-quota-host.exe'
        $missingDatabase = Join-Path $TestDrive 'missing-cc-switch.db'

        $response = Invoke-CcSwitchUsageDiscovery -ExecutablePath $missingExecutable `
            -DatabasePath $missingDatabase -TimeoutMilliseconds 100

        $response.Ok | Should -BeFalse
        $response.Providers | Should -HaveCount 0
        $response.Error.Category | Should -BeExactly 'CcSwitchSchemaUnsupported'
        $response.Error.Message | Should -BeExactly 'CC Switch usage discovery failed.'
        ($response | ConvertTo-Json -Compress) | Should -Not -Match ([regex]::Escape($TestDrive))
    }
}

Describe 'CC Switch usage rule conversion' {
    It 'converts a real-format Wakaka rule into a Generic draft' {
        $descriptor = New-TestCcSwitchDescriptor -IntervalMinutes 47 -Code @'
({
  request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { Authorization: "Bearer {{apiKey}}" } },
  extractor: function(response) { const data = response.data ?? response; return { isValid: true, remaining: data.balance, unit: data.currency ?? "USD" }; }
})
'@

        $candidate = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://api.wkkapi.com' -ImportMode Auto

        $candidate.Status | Should -BeExactly 'Ready'
        $candidate.Draft.ProviderKind | Should -BeExactly 'Generic'
        $candidate.Draft.RequestDefinition.Method | Should -BeExactly 'GET'
        $candidate.Draft.RequestDefinition.Path | Should -BeExactly '/v1/usage'
        $candidate.Draft.RequestDefinition.Headers.Authorization |
            Should -BeExactly 'Bearer {{apiKey}}'
        $candidate.Draft.IntervalMinutes | Should -Be 5
        $candidate.Draft.TrustedDestination | Should -BeNullOrEmpty
        $candidate.Draft.Secrets.ApiKey | Should -BeExactly ''
        $candidate.Link.SourceProviderId | Should -BeExactly 'source-1'
        $candidate.Link.ScriptFingerprint | Should -Match '^[0-9a-f]{64}$'
    }

    It 'converts the DeepSeek built-in balance template into a Generic draft' {
        $raw = New-TestCcSwitchDiscoveryResponse
        $raw.providers = @(New-TestCcSwitchTemplateOnlyProvider)
        $descriptor = (ConvertTo-CcSwitchDiscoveryResponse $raw).Providers[0]

        $candidate = ConvertTo-CcSwitchRelayImportCandidate `
            -Descriptor $descriptor `
            -Endpoint 'https://api.deepseek.com' `
            -ImportMode Auto

        $candidate.Status | Should -BeExactly 'Ready'
        $candidate.Draft.ProviderKind | Should -BeExactly 'Generic'
        $candidate.Draft.RequestDefinition.Path | Should -BeExactly '/user/balance'
        $candidate.Draft.RequestDefinition.Headers.Authorization |
            Should -BeExactly 'Bearer {{apiKey}}'
        $candidate.Draft.ExtractorScript | Should -Match '(?s)^function\(response\)\{.*\}$'
        $candidate.Draft.ExtractorScript | Should -Not -Match '\}\}$'
    }

    It 'requires Custom when any request syntax is not fully understood' -ForEach @(
        @{
            Name = 'dynamic authorization'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:getToken()}},extractor:r=>r})'
        }
        @{
            Name = 'dynamic body'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"POST",body:JSON.stringify({x:1})},extractor:r=>r})'
        }
        @{
            Name = 'unsupported method'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"DELETE"},extractor:r=>r})'
        }
        @{
            Name = 'absolute request target'
            Script = '({request:{url:"https://other.example/v1/usage",method:"GET"},extractor:r=>r})'
        }
        @{
            Name = 'unknown request field'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",credentials:"include"},extractor:r=>r})'
        }
        @{
            Name = 'mixed literal and dynamic headers'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Accept:"application/json",Authorization:getToken()}},extractor:r=>r})'
        }
    ) {
        $conversion = ConvertFrom-RelayUsageScript -Script $Script `
            -BaseUrl 'https://api.wkkapi.com' -TemplateType general

        $conversion.Status | Should -BeExactly 'RequiresCustom'
        $conversion.RequestDefinition | Should -BeNullOrEmpty
        $conversion.ExtractorScript | Should -BeNullOrEmpty
    }

    It 'preserves an uncertain script exactly only after explicit Custom selection' {
        $code = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:getToken()}},extractor:r=>r})'
        $descriptor = New-TestCcSwitchDescriptor -Code $code

        $automatic = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://api.wkkapi.com' -ImportMode Auto
        $custom = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://api.wkkapi.com' -ImportMode Custom

        $automatic.Status | Should -BeExactly 'RequiresCustom'
        $automatic.Draft | Should -BeNullOrEmpty
        $custom.Status | Should -BeExactly 'Ready'
        $custom.Draft.ProviderKind | Should -BeExactly 'Custom'
        $custom.Draft.RequestDefinition | Should -BeNullOrEmpty
        $custom.Draft.ExtractorScript | Should -BeExactly $code
        $custom.Draft.MigrationWarning | Should -BeExactly '已从 CC Switch 导入为 Custom；请检查目标地址并完成测试。'
    }

    It 'never converts a descriptor blocked by the discovery boundary' {
        $descriptor = New-TestCcSwitchDescriptor -ImportStatus CredentialDetected

        { ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://api.wkkapi.com' } |
            Should -Throw 'CC Switch usage script cannot be imported.'
    }

    It 'rejects endpoint credentials, query strings, fragments, and unsupported schemes' -ForEach @(
        @{ Endpoint = 'https://name:password@relay.example' }
        @{ Endpoint = 'https://relay.example?token=value' }
        @{ Endpoint = 'https://relay.example/path#fragment' }
        @{ Endpoint = 'ftp://relay.example' }
    ) {
        $descriptor = New-TestCcSwitchDescriptor

        { ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor -Endpoint $Endpoint } |
            Should -Throw 'CC Switch endpoint is invalid.'
    }

    It 'uses a stable order-independent fingerprint and changes it for import inputs' {
        $first = New-TestCcSwitchDescriptor -EndpointCandidates @(
            'https://b.example', 'https://a.example'
        )
        $same = New-TestCcSwitchDescriptor -EndpointCandidates @(
            'https://a.example', 'https://b.example'
        )
        $fingerprint = Get-CcSwitchUsageScriptFingerprint $first

        Get-CcSwitchUsageScriptFingerprint $same | Should -BeExactly $fingerprint
        Get-CcSwitchUsageScriptFingerprint (
            New-TestCcSwitchDescriptor `
                -Code '({request:{url:"{{baseUrl}}/other",method:"GET"},extractor:r=>r})' `
                -EndpointCandidates @('https://b.example', 'https://a.example')
        ) | Should -Not -BeExactly $fingerprint
        Get-CcSwitchUsageScriptFingerprint (
            New-TestCcSwitchDescriptor -TimeoutSeconds 11 `
                -EndpointCandidates @('https://b.example', 'https://a.example')
        ) | Should -Not -BeExactly $fingerprint
        Get-CcSwitchUsageScriptFingerprint (
            New-TestCcSwitchDescriptor -IntervalMinutes 11 `
                -EndpointCandidates @('https://b.example', 'https://a.example')
        ) | Should -Not -BeExactly $fingerprint
        Get-CcSwitchUsageScriptFingerprint (
            New-TestCcSwitchDescriptor -EndpointCandidates @('https://c.example')
        ) | Should -Not -BeExactly $fingerprint
    }

    It 'preserves update identity and trust only while the origin is unchanged' {
        $descriptor = New-TestCcSwitchDescriptor
        $existing = [pscustomobject][ordered]@{
            Id = '22222222-2222-2222-2222-222222222222'
            Name = 'My relay'
            Enabled = $false
            BaseUrl = 'https://api.wkkapi.com/old-prefix'
            IntervalMinutes = 60
            TrustedDestination = 'https://api.wkkapi.com:443'
        }

        $sameOrigin = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://api.wkkapi.com/new-prefix' -ExistingProvider $existing
        $newOrigin = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
            -Endpoint 'https://other.example' -ExistingProvider $existing

        $sameOrigin.Draft.Id | Should -BeExactly $existing.Id
        $sameOrigin.Draft.Name | Should -BeExactly 'My relay'
        $sameOrigin.Draft.Enabled | Should -BeFalse
        $sameOrigin.Draft.IntervalMinutes | Should -Be 60
        $sameOrigin.Draft.TrustedDestination | Should -BeExactly 'https://api.wkkapi.com:443'
        $newOrigin.Draft.TrustedDestination | Should -BeNullOrEmpty
    }
}

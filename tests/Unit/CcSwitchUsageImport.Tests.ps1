BeforeAll {
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

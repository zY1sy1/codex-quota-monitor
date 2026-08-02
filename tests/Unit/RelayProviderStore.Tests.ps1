BeforeAll {
    $settingsScript = "$PSScriptRoot\..\..\companion\Private\Settings.ps1"
    $storeScript = "$PSScriptRoot\..\..\companion\Private\RelayProviderStore.ps1"
    $presetPath = "$PSScriptRoot\..\..\companion\Presets\relay-usage.json"
    . $settingsScript
    if (Test-Path -LiteralPath $storeScript -PathType Leaf) {
        . $storeScript
    }

    function New-TestRelayProviderDocument {
        param(
            [string]$Id = '3d07f147-5d2d-44e3-9184-cf70acc2b30c',
            [string]$BaseUrl = ' https://api.wkkapi.com ',
            [string]$ApiKey = 'AQIDBA=='
        )

        [ordered]@{
            SchemaVersion = 1
            Providers = [object[]]@(
                [ordered]@{
                    Id = $Id
                    Name = ' Wakaka '
                    Enabled = $true
                    BaseUrl = $BaseUrl
                    TemplateType = 'Wakaka'
                    Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:"Bearer {{apiKey}}"}},extractor:function(response){return response;}})'
                    TimeoutSeconds = 10
                    IntervalMinutes = 10
                    TrustedDestination = $null
                    Secrets = [ordered]@{
                        ApiKey = $ApiKey
                        AccessToken = ''
                        UserId = ''
                    }
                }
            )
        }
    }
}

Describe 'relay provider canonicalization' {
    It 'returns the exact schema-one field order and normalized scalar values' {
        $canonical = ConvertTo-CanonicalRelayProviderDocument -Document (New-TestRelayProviderDocument)
        $provider = $canonical.Providers[0]

        ($canonical.Keys -join ',') | Should -BeExactly 'SchemaVersion,Providers'
        ($provider.Keys -join ',') | Should -BeExactly 'Id,Name,Enabled,BaseUrl,TemplateType,Script,TimeoutSeconds,IntervalMinutes,TrustedDestination,Secrets'
        ($provider.Secrets.Keys -join ',') | Should -BeExactly 'ApiKey,AccessToken,UserId'
        $provider.Id | Should -BeExactly '3d07f147-5d2d-44e3-9184-cf70acc2b30c'
        $provider.Name | Should -BeExactly 'Wakaka'
        $provider.BaseUrl | Should -BeExactly 'https://api.wkkapi.com'
        $provider.Enabled | Should -BeOfType ([bool])
        $provider.TimeoutSeconds | Should -BeOfType ([int])
        $provider.IntervalMinutes | Should -BeOfType ([int])
        $provider.TrustedDestination | Should -BeNullOrEmpty
    }

    It 'rejects duplicate IDs, unknown fields, invalid URLs, malformed ciphers, and invalid ranges' -ForEach @(
        @{ Name = 'duplicate IDs'; Mutate = { param($document) $document.Providers = [object[]]@($document.Providers[0], $document.Providers[0]) } }
        @{ Name = 'unknown root field'; Mutate = { param($document) $document['Future'] = $true } }
        @{ Name = 'unknown provider field'; Mutate = { param($document) $document.Providers[0]['Password'] = 'sentinel' } }
        @{ Name = 'unknown secret field'; Mutate = { param($document) $document.Providers[0].Secrets['Cookie'] = 'AQID' } }
        @{ Name = 'invalid URL'; Mutate = { param($document) $document.Providers[0]['BaseUrl'] = 'not a URL' } }
        @{ Name = 'malformed cipher'; Mutate = { param($document) $document.Providers[0].Secrets['ApiKey'] = 'not-base64!' } }
        @{ Name = 'timeout below range'; Mutate = { param($document) $document.Providers[0]['TimeoutSeconds'] = 1 } }
        @{ Name = 'interval above range'; Mutate = { param($document) $document.Providers[0]['IntervalMinutes'] = 1441 } }
    ) {
        $document = New-TestRelayProviderDocument
        & $Mutate $document

        ConvertTo-CanonicalRelayProviderDocument -Document $document | Should -BeNullOrEmpty
    }
}

Describe 'relay provider persistence' {
    It 'round-trips atomically without a BOM, temp file, or plaintext sentinel' {
        $path = Join-Path $TestDrive 'round-trip\relay-providers.json'
        $plainTextSentinel = 'PLAINTEXT_API_KEY_SENTINEL_430'
        $document = New-TestRelayProviderDocument -ApiKey (
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('cipher-bytes-only'))
        )

        Write-RelayProviderStore -Path $path -Document $document

        $bytes = [IO.File]::ReadAllBytes($path)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        $bytes[0..([Math]::Min(2, $bytes.Length - 1))] -join ',' | Should -Not -BeExactly '239,187,191'
        $json | Should -Not -Match ([regex]::Escape($plainTextSentinel))
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
        (Read-RelayProviderStore -Path $path).Providers[0].Name | Should -BeExactly 'Wakaka'
    }

    It 'returns a fresh empty schema-one store when the file is missing' {
        $path = Join-Path $TestDrive 'missing\relay-providers.json'
        $first = Read-RelayProviderStore -Path $path
        $first.Providers += (New-TestRelayProviderDocument).Providers
        $second = Read-RelayProviderStore -Path $path

        @($second.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'quarantines the complete invalid document with a deterministic UTC suffix' -ForEach @(
        @{ Name = 'duplicate'; Mutate = { param($document) $document.Providers = [object[]]@($document.Providers[0], $document.Providers[0]) } }
        @{ Name = 'unknown'; Mutate = { param($document) $document.Providers[0]['Unexpected'] = $true } }
        @{ Name = 'url'; Mutate = { param($document) $document.Providers[0]['BaseUrl'] = 'invalid' } }
        @{ Name = 'cipher'; Mutate = { param($document) $document.Providers[0].Secrets['ApiKey'] = '%' } }
    ) {
        $path = Join-Path $TestDrive "$Name\relay-providers.json"
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        $document = New-TestRelayProviderDocument
        & $Mutate $document
        $evidence = $document | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($path, $evidence, [Text.UTF8Encoding]::new($false))

        $loaded = Read-RelayProviderStore -Path $path -Now ([DateTimeOffset]'2026-08-02T01:02:03.004Z')

        @($loaded.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
        $quarantine = "$path.corrupt-20260802T010203004Z"
        Test-Path -LiteralPath $quarantine -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($quarantine) | Should -BeExactly $evidence
    }

    It 'rejects invalid caller documents with one constant message and writes nothing' {
        $path = Join-Path $TestDrive 'invalid-write\relay-providers.json'
        $document = New-TestRelayProviderDocument
        $document.Providers[0].Secrets['ApiKey'] = 'plaintext sentinel'

        { Write-RelayProviderStore -Path $path -Document $document } |
            Should -Throw -ExpectedMessage 'Relay provider document does not match the supported schema.'
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'relay usage preset registry' {
    It 'contains the three supported non-secret presets with exact endpoints and defaults' {
        $registry = Get-Content -LiteralPath $presetPath -Raw | ConvertFrom-Json

        $registry.SchemaVersion | Should -Be 1
        @($registry.Presets.Id) | Should -BeExactly @('wakaka', 'general', 'new-api')
        @($registry.Presets.EndpointPath) | Should -BeExactly @('/v1/usage', '/user/balance', '/api/user/self')
        @($registry.Presets.DefaultTimeoutSeconds | Select-Object -Unique) | Should -BeExactly @(10)
        @($registry.Presets.DefaultIntervalMinutes | Select-Object -Unique) | Should -BeExactly @(10)
        foreach ($preset in $registry.Presets) {
            $preset.Script | Should -Not -BeNullOrEmpty
            $preset.PSObject.Properties.Name | Should -Not -Contain 'Secrets'
        }
        ($registry | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match 'PLAINTEXT_API_KEY_SENTINEL_430|Bearer sk-|password-value|cookie-value'
    }
}

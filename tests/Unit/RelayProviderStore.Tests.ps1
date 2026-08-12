BeforeAll {
    $settingsScript = "$PSScriptRoot\..\..\companion\Private\Settings.ps1"
    $credentialsScript = "$PSScriptRoot\..\..\companion\Private\RelayCredentials.ps1"
    $storeScript = "$PSScriptRoot\..\..\companion\Private\RelayProviderStore.ps1"
    $presetPath = "$PSScriptRoot\..\..\companion\Presets\relay-usage.json"
    . $settingsScript
    . $credentialsScript
    . $storeScript

    function New-TestSecrets {
        param(
            [string]$ApiKey = 'AQIDBA==',
            [string]$AccessToken = '',
            [string]$UserId = ''
        )

        [ordered]@{
            ApiKey = $ApiKey
            AccessToken = $AccessToken
            UserId = $UserId
        }
    }

    function New-TestRequestDefinition {
        param(
            [string]$Path = '/v1/usage',
            [string]$Authorization = 'Bearer {{apiKey}}',
            [string]$Method = 'GET'
        )

        [ordered]@{
            Method = $Method
            Path = $Path
            Query = [ordered]@{}
            Headers = [ordered]@{ Authorization = $Authorization }
            Body = $null
        }
    }

    function New-TestSchemaTwoDocument {
        param(
            [string]$Id = '3d07f147-5d2d-44e3-9184-cf70acc2b30c',
            [string]$BaseUrl = ' https://api.wkkapi.com ',
            [string]$ApiKey = 'AQIDBA=='
        )

        [ordered]@{
            SchemaVersion = 2
            Providers = [object[]]@(
                [ordered]@{
                    Id = $Id
                    Name = ' Wakaka '
                    Enabled = $true
                    ProviderKind = 'Generic'
                    BaseUrl = $BaseUrl
                    RequestDefinition = New-TestRequestDefinition
                    ExtractorScript = 'function(response){return response;}'
                    TimeoutSeconds = 10
                    IntervalMinutes = 10
                    TrustedDestination = $null
                    Secrets = New-TestSecrets -ApiKey $ApiKey
                }
            )
        }
    }

    function New-TestLegacyProviderDocument {
        param(
            [string]$TemplateType = 'Wakaka',
            [string]$Id = '3d07f147-5d2d-44e3-9184-cf70acc2b30c',
            [string]$BaseUrl = ' https://api.wkkapi.com ',
            [string]$Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:"Bearer {{apiKey}}"}},extractor:function(response){return response;}})',
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
                    TemplateType = $TemplateType
                    Script = $Script
                    TimeoutSeconds = 10
                    IntervalMinutes = 10
                    TrustedDestination = $null
                    Secrets = New-TestSecrets -ApiKey $ApiKey
                }
            )
        }
    }

    function Write-TestJson {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$Document
        )

        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllText(
            $Path,
            ($Document | ConvertTo-Json -Depth 12 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
    }
}

Describe 'relay provider canonicalization' {
    It 'returns the exact schema-two field order and normalized scalar values' {
        $canonical = ConvertTo-CanonicalRelayProviderDocument -Document (New-TestSchemaTwoDocument)
        $provider = $canonical.Providers[0]

        ($canonical.Keys -join ',') | Should -BeExactly 'SchemaVersion,Providers'
        ($provider.Keys -join ',') | Should -BeExactly 'Id,Name,Enabled,ProviderKind,BaseUrl,RequestDefinition,ExtractorScript,TimeoutSeconds,IntervalMinutes,TrustedDestination,Secrets'
        ($provider.RequestDefinition.Keys -join ',') | Should -BeExactly 'Method,Path,Query,Headers,Body'
        ($provider.Secrets.Keys -join ',') | Should -BeExactly 'ApiKey,AccessToken,UserId'
        $canonical.SchemaVersion | Should -Be 2
        $provider.Id | Should -BeExactly '3d07f147-5d2d-44e3-9184-cf70acc2b30c'
        $provider.Name | Should -BeExactly 'Wakaka'
        $provider.ProviderKind | Should -BeExactly 'Generic'
        $provider.BaseUrl | Should -BeExactly 'https://api.wkkapi.com'
        $provider.RequestDefinition.Method | Should -BeExactly 'GET'
        $provider.RequestDefinition.Path | Should -BeExactly '/v1/usage'
        $provider.Enabled | Should -BeOfType ([bool])
        $provider.TimeoutSeconds | Should -BeOfType ([int])
        $provider.IntervalMinutes | Should -BeOfType ([int])
        $provider.TrustedDestination | Should -BeNullOrEmpty
    }

    It 'canonicalizes a custom provider with a null request definition' {
        $document = New-TestSchemaTwoDocument
        $document.Providers[0].ProviderKind = 'Custom'
        $document.Providers[0].RequestDefinition = $null
        $document.Providers[0].ExtractorScript = '({request:{url:"{{baseUrl}}/custom",method:"POST"},extractor:r=>r})'

        $provider = (ConvertTo-CanonicalRelayProviderDocument -Document $document).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Custom'
        $provider.RequestDefinition | Should -BeNullOrEmpty
        $provider.ExtractorScript | Should -BeExactly '({request:{url:"{{baseUrl}}/custom",method:"POST"},extractor:r=>r})'
    }

    It 'rejects duplicate IDs, unknown fields, invalid URLs, malformed ciphers, invalid ranges, and invalid requests' -ForEach @(
        @{ Name = 'duplicate IDs'; Mutate = { param($document) $document.Providers = [object[]]@($document.Providers[0], $document.Providers[0]) } }
        @{ Name = 'unknown root field'; Mutate = { param($document) $document['Future'] = $true } }
        @{ Name = 'unknown provider field'; Mutate = { param($document) $document.Providers[0]['Password'] = 'sentinel' } }
        @{ Name = 'unknown secret field'; Mutate = { param($document) $document.Providers[0].Secrets['Cookie'] = 'AQID' } }
        @{ Name = 'invalid URL'; Mutate = { param($document) $document.Providers[0]['BaseUrl'] = 'not a URL' } }
        @{ Name = 'malformed cipher'; Mutate = { param($document) $document.Providers[0].Secrets['ApiKey'] = 'not-base64!' } }
        @{ Name = 'timeout below range'; Mutate = { param($document) $document.Providers[0]['TimeoutSeconds'] = 1 } }
        @{ Name = 'interval above range'; Mutate = { param($document) $document.Providers[0]['IntervalMinutes'] = 1441 } }
        @{ Name = 'absolute request URL'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Path = 'https://evil.example/path' } }
        @{ Name = 'network path request URL'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Path = '//evil.example/path' } }
        @{ Name = 'request fragment'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Path = '/v1/usage#fragment' } }
        @{ Name = 'invalid method'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Method = 'DELETE' } }
        @{ Name = 'invalid query map'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Query = @('not-a-map') } }
        @{ Name = 'non-string header value'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Headers.Authorization = 42 } }
        @{ Name = 'control character'; Mutate = { param($document) $document.Providers[0].RequestDefinition.Headers.Authorization = "Bearer`n{{apiKey}}" } }
        @{ Name = 'generic missing extractor'; Mutate = { param($document) $document.Providers[0].ExtractorScript = '' } }
        @{ Name = 'generic extractor is not a function expression'; Mutate = { param($document) $document.Providers[0].ExtractorScript = 'return response;' } }
        @{ Name = 'custom request is not null'; Mutate = { param($document) $document.Providers[0].ProviderKind = 'Custom'; $document.Providers[0].RequestDefinition = New-TestRequestDefinition } }
    ) {
        $document = New-TestSchemaTwoDocument
        & $Mutate $document

        ConvertTo-CanonicalRelayProviderDocument -Document $document | Should -BeNullOrEmpty
    }
}

Describe 'relay provider schema-one migration' {
    It 'migrates Wakaka to the canonical generic request and preserves its extractor' {
        $legacy = New-TestLegacyProviderDocument -TemplateType Wakaka
        $path = Join-Path $TestDrive 'wakaka\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Generic'
        $provider.RequestDefinition.Method | Should -BeExactly 'GET'
        $provider.RequestDefinition.Path | Should -BeExactly '/v1/usage'
        $provider.RequestDefinition.Headers.Authorization | Should -BeExactly 'Bearer {{apiKey}}'
        $provider.ExtractorScript | Should -BeExactly 'function(response){return response;}'
        $provider.TrustedDestination | Should -BeExactly 'https://api.wkkapi.com:443'
    }

    It 'migrates General and extracts its request from the legacy script' {
        $script = '({request:{url:"{{baseUrl}}/user/balance",method:"GET",headers:{Authorization:"Bearer {{apiKey}}"}},extractor:function(response){return response.data;}})'
        $legacy = New-TestLegacyProviderDocument -TemplateType General -Script $script
        $path = Join-Path $TestDrive 'general\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Generic'
        $provider.RequestDefinition.Path | Should -BeExactly '/user/balance'
        $provider.RequestDefinition.Headers.Authorization | Should -BeExactly 'Bearer {{apiKey}}'
        $provider.ExtractorScript | Should -BeExactly 'function(response){return response.data;}'
    }

    It 'migrates NewApi and preserves both legacy request headers' {
        $script = '({request:{url:"{{baseUrl}}/api/user/self",method:"GET",headers:{Authorization:"Bearer {{accessToken}}","New-Api-User":"{{userId}}"}},extractor:r=>r.data})'
        $legacy = New-TestLegacyProviderDocument -TemplateType NewApi -BaseUrl 'https://new-api.example' -Script $script
        $path = Join-Path $TestDrive 'new-api\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Generic'
        $provider.RequestDefinition.Path | Should -BeExactly '/api/user/self'
        $provider.RequestDefinition.Headers.Authorization | Should -BeExactly 'Bearer {{accessToken}}'
        $provider.RequestDefinition.Headers.'New-Api-User' | Should -BeExactly '{{userId}}'
        $provider.ExtractorScript | Should -BeExactly 'r=>r.data'
        $provider.TrustedDestination | Should -BeExactly 'https://new-api.example:443'
    }

    It 'migrates Custom by retaining the complete legacy script' {
        $script = '({request:{url:"{{baseUrl}}/custom",method:"POST",body:"sentinel"},extractor:r=>r})'
        $legacy = New-TestLegacyProviderDocument -TemplateType Custom -Script $script
        $path = Join-Path $TestDrive 'custom\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Custom'
        $provider.RequestDefinition | Should -BeNullOrEmpty
        $provider.ExtractorScript | Should -BeExactly $script
    }

    It 'falls back to Custom without dropping a legacy provider whose request is unsafe' {
        $script = '({request:{url:"https://evil.example/steal",method:"GET"},extractor:r=>r})'
        $legacy = New-TestLegacyProviderDocument -TemplateType General -Script $script
        $path = Join-Path $TestDrive 'fallback\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Custom'
        $provider.RequestDefinition | Should -BeNullOrEmpty
        $provider.ExtractorScript | Should -BeExactly $script
    }

    It 'falls back to Custom without partially consuming uncertain request syntax' -ForEach @(
        @{ Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:getToken()}},extractor:r=>r})' }
        @{ Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"POST",body:JSON.stringify({x:1})},extractor:r=>r})' }
        @{ Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"DELETE"},extractor:r=>r})' }
        @{ Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",credentials:"include"},extractor:r=>r})' }
    ) {
        $legacy = New-TestLegacyProviderDocument -TemplateType General -Script $Script
        $path = Join-Path $TestDrive ("full-consumption\$([guid]::NewGuid()).json")
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Custom'
        $provider.RequestDefinition | Should -BeNullOrEmpty
        $provider.ExtractorScript | Should -BeExactly $Script
    }

    It 'falls back to Custom without dropping an unknown legacy script' {
        $script = 'legacy-unknown-script-sentinel'
        $legacy = New-TestLegacyProviderDocument -TemplateType Unknown -Script $script
        $path = Join-Path $TestDrive 'unknown\relay-providers.json'
        Write-TestJson -Path $path -Document $legacy

        $provider = (Read-RelayProviderStore -Path $path).Providers[0]

        $provider.ProviderKind | Should -BeExactly 'Custom'
        $provider.RequestDefinition | Should -BeNullOrEmpty
        $provider.ExtractorScript | Should -BeExactly $script
    }

    It 'migrates providers independently when one provider is malformed' {
        $document = New-TestLegacyProviderDocument
        $document.Providers = [object[]]@(
            $document.Providers[0],
            [ordered]@{ Id = 'not-a-guid'; Unexpected = $true }
        )
        $path = Join-Path $TestDrive 'independent\relay-providers.json'
        Write-TestJson -Path $path -Document $document

        $loaded = Read-RelayProviderStore -Path $path

        @($loaded.Providers).Count | Should -Be 1
        $loaded.Providers[0].ProviderKind | Should -BeExactly 'Generic'
    }
}

Describe 'relay provider persistence' {
    It 'round-trips atomically without a BOM, temp file, or plaintext sentinel' {
        $path = Join-Path $TestDrive 'round-trip\relay-providers.json'
        $plainTextSentinel = 'PLAINTEXT_API_KEY_SENTINEL_430'
        $cipherText = Protect-RelaySecret -PlainText $plainTextSentinel -ProtectBytes {
            param($bytes)
            ,([byte[]]($bytes | ForEach-Object { $_ -bxor 0xA5 }))
        }
        $document = New-TestSchemaTwoDocument -ApiKey $cipherText

        Write-RelayProviderStore -Path $path -Document $document

        $bytes = [IO.File]::ReadAllBytes($path)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        $bytes[0..([Math]::Min(2, $bytes.Length - 1))] -join ',' | Should -Not -BeExactly '239,187,191'
        $json | Should -Not -Match ([regex]::Escape($plainTextSentinel))
        $json | Should -Match ([regex]::Escape($cipherText))
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
        (Read-RelayProviderStore -Path $path).Providers[0].Name | Should -BeExactly 'Wakaka'
    }

    It 'returns a fresh empty schema-two store when the file is missing' {
        $path = Join-Path $TestDrive 'missing\relay-providers.json'
        $first = Read-RelayProviderStore -Path $path
        $first.SchemaVersion | Should -Be 2
        $first.Providers += (New-TestSchemaTwoDocument).Providers
        $second = Read-RelayProviderStore -Path $path

        $second.SchemaVersion | Should -Be 2
        @($second.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'rewrites a legacy document once and leaves the second read byte-identical' {
        $path = Join-Path $TestDrive 'idempotent\relay-providers.json'
        Write-TestJson -Path $path -Document (New-TestLegacyProviderDocument)

        $null = Read-RelayProviderStore -Path $path
        $firstBytes = [IO.File]::ReadAllBytes($path)
        $firstJson = [Text.Encoding]::UTF8.GetString($firstBytes)
        $null = Read-RelayProviderStore -Path $path
        $secondBytes = [IO.File]::ReadAllBytes($path)

        $firstJson | Should -Match '"SchemaVersion":2'
        [Convert]::ToBase64String($secondBytes) | Should -BeExactly ([Convert]::ToBase64String($firstBytes))
        $firstJson | Should -Not -Match '"TemplateType"|"Script":'
    }

    It 'rejects schema-one caller documents and writes nothing' {
        $path = Join-Path $TestDrive 'invalid-write\relay-providers.json'

        { Write-RelayProviderStore -Path $path -Document (New-TestLegacyProviderDocument) } |
            Should -Throw -ExpectedMessage 'Relay provider document does not match the supported schema.'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'quarantines an invalid root document with a deterministic UTC suffix' {
        $path = Join-Path $TestDrive 'invalid-root\relay-providers.json'
        $document = [ordered]@{ SchemaVersion = 2; Providers = 'not-an-array' }
        $evidence = $document | ConvertTo-Json -Depth 8 -Compress
        Write-TestJson -Path $path -Document $document

        $loaded = Read-RelayProviderStore -Path $path -Now ([DateTimeOffset]'2026-08-02T01:02:03.004Z')

        $loaded.SchemaVersion | Should -Be 2
        @($loaded.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
        $quarantine = "$path.corrupt-20260802T010203004Z"
        Test-Path -LiteralPath $quarantine -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($quarantine) | Should -BeExactly $evidence
    }
}

Describe 'relay usage preset registry' {
    It 'contains the three supported non-secret Generic presets with exact request paths and defaults' {
        $registry = Get-Content -LiteralPath $presetPath -Raw | ConvertFrom-Json

        $registry.SchemaVersion | Should -Be 2
        @($registry.Presets.Id) | Should -BeExactly @('wakaka', 'general', 'new-api')
        @($registry.Presets.ProviderKind | Select-Object -Unique) | Should -BeExactly @('Generic')
        @($registry.Presets.RequestDefinition.Path) | Should -BeExactly @('/v1/usage', '/user/balance', '/api/user/self')
        @($registry.Presets.DefaultTimeoutSeconds | Select-Object -Unique) | Should -BeExactly @(10)
        @($registry.Presets.DefaultIntervalMinutes | Select-Object -Unique) | Should -BeExactly @(10)
        foreach ($preset in $registry.Presets) {
            $preset.ExtractorScript | Should -Not -BeNullOrEmpty
            $preset.RequestDefinition.Method | Should -BeExactly 'GET'
            $preset.PSObject.Properties.Name | Should -Not -Contain 'Secrets'
        }
        ($registry | ConvertTo-Json -Depth 8 -Compress) |
            Should -Not -Match 'PLAINTEXT_API_KEY_SENTINEL_430|Bearer sk-|password-value|cookie-value'
    }
}

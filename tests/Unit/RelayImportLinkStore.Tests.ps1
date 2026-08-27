BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\Settings.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayProviderStore.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayImportLinkStore.ps1')

    function New-TestRelayImportLink {
        param(
            [string]$RelayProviderId = '11111111-1111-1111-1111-111111111111',
            [string]$SourceProviderId = 'source-1',
            [string]$SourceAppType = 'codex',
            [string]$Fingerprint = ('a' * 64)
        )
        [ordered]@{
            RelayProviderId = $RelayProviderId
            SourceKind = 'CcSwitchUsageScript'
            SourceProviderId = $SourceProviderId
            SourceAppType = $SourceAppType
            ScriptFingerprint = $Fingerprint
        }
    }

    function New-TestRelayImportLinkDocument {
        param([object[]]$Links = @((New-TestRelayImportLink)))
        [ordered]@{ SchemaVersion = 1; Links = [object[]]$Links }
    }

    function New-TestRelayProviderDocumentForImport {
        param(
            [string]$Id = '11111111-1111-1111-1111-111111111111',
            [string]$Name = 'Relay'
        )
        [ordered]@{
            SchemaVersion = 2
            Providers = [object[]]@([ordered]@{
                Id = $Id
                Name = $Name
                Enabled = $true
                ProviderKind = 'Generic'
                BaseUrl = 'https://relay.example'
                RequestDefinition = [ordered]@{
                    Method = 'GET'
                    Path = '/v1/usage'
                    Query = [ordered]@{}
                    Headers = [ordered]@{ Authorization = 'Bearer {{apiKey}}' }
                    Body = $null
                }
                ExtractorScript = 'function(response){return response;}'
                TimeoutSeconds = 10
                IntervalMinutes = 10
                TrustedDestination = $null
                Secrets = [ordered]@{ ApiKey=''; AccessToken=''; UserId='' }
            })
        }
    }
}

Describe 'relay import link canonicalization and persistence' {
    It 'round-trips the exact non-secret link schema' {
        $path = Join-Path $TestDrive 'round-trip\relay-import-links.json'
        $document = New-TestRelayImportLinkDocument

        Write-RelayImportLinkStore -Path $path -Document $document
        $read = Read-RelayImportLinkStore -Path $path

        ($read.PSObject.Properties.Name -join ',') | Should -BeExactly 'SchemaVersion,Links'
        ($read.Links[0].PSObject.Properties.Name -join ',') |
            Should -BeExactly 'RelayProviderId,SourceKind,SourceProviderId,SourceAppType,ScriptFingerprint'
        $read.SchemaVersion | Should -Be 1
        $read.Links[0].RelayProviderId | Should -BeExactly '11111111-1111-1111-1111-111111111111'
        (Get-Content -Raw $path) |
            Should -Not -Match 'apiKey|accessToken|"token"|balance|BaseUrl|ExtractorScript|"Code"'
        [IO.File]::ReadAllBytes($path)[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp') | Should -HaveCount 0
    }

    It 'returns a fresh empty document for a missing file' {
        $path = Join-Path $TestDrive 'missing\relay-import-links.json'
        $first = Read-RelayImportLinkStore -Path $path
        $first.Links = @((New-TestRelayImportLink))

        $second = Read-RelayImportLinkStore -Path $path

        $second.SchemaVersion | Should -Be 1
        $second.Links | Should -HaveCount 0
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'rejects duplicate IDs, duplicate source tuples, malformed hashes, and expanded shapes' -ForEach @(
        @{
            Name = 'duplicate relay IDs'
            MakeLinks = {
                @((New-TestRelayImportLink), (New-TestRelayImportLink -SourceProviderId 'source-2'))
            }
        }
        @{
            Name = 'duplicate source tuples'
            MakeLinks = {
                @(
                    (New-TestRelayImportLink),
                    (New-TestRelayImportLink -RelayProviderId '22222222-2222-2222-2222-222222222222')
                )
            }
        }
        @{
            Name = 'uppercase hash'
            MakeLinks = { @((New-TestRelayImportLink -Fingerprint ('A' * 64))) }
        }
        @{
            Name = 'short hash'
            MakeLinks = { @((New-TestRelayImportLink -Fingerprint ('a' * 63))) }
        }
        @{
            Name = 'invalid relay ID'
            MakeLinks = { @((New-TestRelayImportLink -RelayProviderId 'not-a-guid')) }
        }
        @{
            Name = 'control character'
            MakeLinks = { @((New-TestRelayImportLink -SourceAppType "codex`n")) }
        }
    ) {
        ConvertTo-CanonicalRelayImportLinkDocument -Document (
            New-TestRelayImportLinkDocument -Links @(& $MakeLinks)
        ) | Should -BeNullOrEmpty
    }

    It 'rejects unknown root and link fields' {
        $root = New-TestRelayImportLinkDocument
        $root['Future'] = $true
        ConvertTo-CanonicalRelayImportLinkDocument $root | Should -BeNullOrEmpty

        $link = New-TestRelayImportLink
        $link['ApiKey'] = 'secret'
        ConvertTo-CanonicalRelayImportLinkDocument (
            New-TestRelayImportLinkDocument -Links @($link)
        ) | Should -BeNullOrEmpty
    }

    It 'quarantines corrupt content and returns an empty document' {
        $path = Join-Path $TestDrive 'corrupt\relay-import-links.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, '{not-json', [Text.UTF8Encoding]::new($false))
        $now = [DateTimeOffset]::Parse('2026-08-11T01:02:03.456Z')

        $read = Read-RelayImportLinkStore -Path $path -Now $now

        $read.Links | Should -HaveCount 0
        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath "$path.corrupt-20260811T010203456Z" | Should -BeTrue
    }
}

Describe 'relay import link mutations' {
    It 'canonicalizes None, Upsert, source transfer, and Remove mutations' {
        $original = New-TestRelayImportLinkDocument

        $none = Update-RelayImportLinkDocument -Document $original `
            -Mutation (New-RelayImportLinkMutation -Kind None)
        $none.Links | Should -HaveCount 1

        $replacement = New-TestRelayImportLink -Fingerprint ('b' * 64)
        $updated = Update-RelayImportLinkDocument -Document $original `
            -Mutation (New-RelayImportLinkMutation -Kind Upsert -Link $replacement)
        $updated.Links | Should -HaveCount 1
        $updated.Links[0].ScriptFingerprint | Should -BeExactly ('b' * 64)

        $copy = New-TestRelayImportLink -RelayProviderId '22222222-2222-2222-2222-222222222222'
        $transferred = Update-RelayImportLinkDocument -Document $original `
            -Mutation (New-RelayImportLinkMutation -Kind Upsert -Link $copy)
        $transferred.Links | Should -HaveCount 1
        $transferred.Links[0].RelayProviderId | Should -BeExactly '22222222-2222-2222-2222-222222222222'

        $removed = Update-RelayImportLinkDocument -Document $transferred `
            -Mutation (New-RelayImportLinkMutation -Kind Remove `
                -ProviderId '22222222-2222-2222-2222-222222222222')
        $removed.Links | Should -HaveCount 0
    }
}

Describe 'relay provider and import link transaction' {
    It 'writes both canonical documents on success' {
        $providerPath = Join-Path $TestDrive 'success\relay-providers.json'
        $linkPath = Join-Path $TestDrive 'success\relay-import-links.json'
        $providers = New-TestRelayProviderDocumentForImport
        $mutation = New-RelayImportLinkMutation -Kind Upsert -Link (New-TestRelayImportLink)

        Write-RelayProviderImportTransaction -ProviderPath $providerPath -LinkPath $linkPath `
            -ProviderDocument $providers -Mutation $mutation

        (Read-RelayProviderStore -Path $providerPath).Providers[0].Name | Should -BeExactly 'Relay'
        (Read-RelayImportLinkStore -Path $linkPath).Links[0].SourceProviderId |
            Should -BeExactly 'source-1'
    }

    It 'restores both original byte sequences when the link write fails' {
        $providerPath = Join-Path $TestDrive 'rollback\relay-providers.json'
        $linkPath = Join-Path $TestDrive 'rollback\relay-import-links.json'
        Write-RelayProviderStore -Path $providerPath `
            -Document (New-TestRelayProviderDocumentForImport -Name 'Original')
        Write-RelayImportLinkStore -Path $linkPath -Document (New-TestRelayImportLinkDocument)
        $providerBefore = [IO.File]::ReadAllBytes($providerPath)
        $linkBefore = [IO.File]::ReadAllBytes($linkPath)
        $nextProviders = New-TestRelayProviderDocumentForImport -Name 'Changed'
        $nextLink = New-TestRelayImportLink -Fingerprint ('b' * 64)

        {
            Write-RelayProviderImportTransaction -ProviderPath $providerPath -LinkPath $linkPath `
                -ProviderDocument $nextProviders `
                -Mutation (New-RelayImportLinkMutation -Kind Upsert -Link $nextLink) `
                -ReplaceLinkFile {
                    param($Path, $Document)
                    Write-RelayImportLinkStore -Path $Path -Document $Document
                    throw 'injected link failure after replacement'
                }
        } | Should -Throw 'Relay provider import transaction failed and was rolled back.'

        [Convert]::ToHexString([IO.File]::ReadAllBytes($providerPath)) |
            Should -BeExactly ([Convert]::ToHexString($providerBefore))
        [Convert]::ToHexString([IO.File]::ReadAllBytes($linkPath)) |
            Should -BeExactly ([Convert]::ToHexString($linkBefore))
    }

    It 'removes a newly created provider file when the first link write fails' {
        $providerPath = Join-Path $TestDrive 'new-rollback\relay-providers.json'
        $linkPath = Join-Path $TestDrive 'new-rollback\relay-import-links.json'

        {
            Write-RelayProviderImportTransaction -ProviderPath $providerPath -LinkPath $linkPath `
                -ProviderDocument (New-TestRelayProviderDocumentForImport) `
                -Mutation (New-RelayImportLinkMutation -Kind Upsert -Link (New-TestRelayImportLink)) `
                -ReplaceLinkFile { param($Path, $Document) throw 'injected link failure' }
        } | Should -Throw 'Relay provider import transaction failed and was rolled back.'

        Test-Path -LiteralPath $providerPath | Should -BeFalse
        Test-Path -LiteralPath $linkPath | Should -BeFalse
    }
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}

Describe 'generic relay provider documentation' {
    It 'documents Generic providers and schema-two migration' {
        $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')
        $readme | Should -Match '通用中转站'
        $readme | Should -Match 'ProviderKind'
        $readme | Should -Match 'Schema 1'
        $readme | Should -Match 'POST'

        $migrationPath = Join-Path $script:RepoRoot 'docs\relay-provider-migration.md'
        $examplePath = Join-Path $script:RepoRoot 'docs\examples\generic-relay-provider.json'
        Test-Path -LiteralPath $migrationPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $examplePath -PathType Leaf | Should -BeTrue

        $migration = Get-Content -Raw $migrationPath
        $migration | Should -Match 'DestinationTrustRequired'
        $migration | Should -Match '明文 HTTP'
        $migration | Should -Match '不会写入日志、缓存、健康状态'
        $migration | Should -Match '官方 Codex 额度'

        $example = Get-Content -Raw $examplePath | ConvertFrom-Json
        $example.SchemaVersion | Should -Be 2
        @($example.Providers).Count | Should -Be 2
        $example.Providers[0].RequestDefinition.Method | Should -BeExactly 'GET'
        $example.Providers[1].RequestDefinition.Method | Should -BeExactly 'POST'
        $example.Providers[0].RequestDefinition.Headers.Authorization | Should -Match '\{\{apiKey\}\}'
        $example.Providers[1].RequestDefinition.Headers.Authorization | Should -Match '\{\{accessToken\}\}'
        $example.Providers[1].RequestDefinition.Headers.'X-User-Id' | Should -Match '\{\{userId\}\}'
        ($example | ConvertTo-Json -Depth 20 -Compress) | Should -Not -Match 'api-secret|access-secret|real-token'
    }

    It 'documents the complete CC Switch usage-script import boundary and workflow' {
        $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')
        $migration = Get-Content -Raw (
            Join-Path $script:RepoRoot 'docs\relay-provider-migration.md'
        )
        foreach ($document in @($readme, $migration)) {
            $document | Should -Match '从 CC Switch 导入'
            $document | Should -Match '只读'
            $document | Should -Match 'settings_config'
            $document | Should -Match 'usage_script\.apiKey'
            $document | Should -Match 'Generic'
            $document | Should -Match 'Custom'
            $document | Should -Match '测试.*保存'
            $document | Should -Match '来源链接.*独立'
        }
        foreach ($category in @(
            'EndpointNotFound', 'InvalidJson', 'ExtractorExecution',
            'ResultValidation', 'RateLimit', 'DestinationTrustRequired'
        )) {
            $migration | Should -Match ([regex]::Escape($category))
        }
        $migration | Should -Match '不会猜测|不猜测'
        $migration | Should -Match '没有可用的余额接口'
    }
}

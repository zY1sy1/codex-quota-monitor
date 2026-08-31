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
        @($example.Providers.IntervalMinutes | Select-Object -Unique) |
            Should -BeExactly @(5)
        $example.Providers[0].RequestDefinition.Method | Should -BeExactly 'GET'
        $example.Providers[1].RequestDefinition.Method | Should -BeExactly 'POST'
        $example.Providers[0].RequestDefinition.Headers.Authorization | Should -Match '\{\{apiKey\}\}'
        $example.Providers[1].RequestDefinition.Headers.Authorization | Should -Match '\{\{accessToken\}\}'
        $example.Providers[1].RequestDefinition.Headers.'X-User-Id' | Should -Match '\{\{userId\}\}'
        ($example | ConvertTo-Json -Depth 20 -Compress) | Should -Not -Match 'api-secret|access-secret|real-token'
    }

    It 'documents independent relay intervals and rejects the former global settings interval' {
        $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')
        $settingsSectionMatch = [regex]::Match(
            $readme,
            '## 设置(?s:.*?)(?=## 中转站额度)'
        )
        $settingsSectionMatch.Success | Should -BeTrue
        $settingsSection = $settingsSectionMatch.Value

        $readme | Should -Match '每个中转站.*独立.*0[–-]1440.*分钟'
        $readme | Should -Match '新建.*首次导入.*5.*分钟'
        $readme | Should -Match '0.*手动.*立即刷新.*手动测试'
        $readme | Should -Match '修改.*一个中转站.*不会影响.*其他'
        $settingsSection | Should -Not -Match '自动查询间隔'
        $readme | Should -Not -Match '设置窗口中的全局自动查询间隔|统一覆盖所有启用的中转站|全局自动查询间隔'
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

    It 'documents provider-specific query intervals and the five-minute default' {
        $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')

        $readme | Should -Match '每个中转站.*查询间隔'
        $readme | Should -Match '默认.*5 分钟'
        $readme | Should -Match '0.*手动'
    }
}

Describe 'Windows installer documentation' {
    It 'documents recipient installation, upgrade, uninstall, and build behavior' {
        $readmePath = Join-Path $script:RepoRoot 'README.md'
        $installerReadmePath = Join-Path $script:RepoRoot 'installer\README.md'
        Test-Path -LiteralPath $installerReadmePath -PathType Leaf | Should -BeTrue

        $documents = @(
            (Get-Content -LiteralPath $readmePath -Raw)
            (Get-Content -LiteralPath $installerReadmePath -Raw)
        ) -join "`n"
        foreach ($pattern in @(
                'CodexQuotaMonitor-Setup-<version>-x64\.exe',
                'Windows 11 x64',
                'PowerShell 7\.6\.4',
                '不需要管理员|无需管理员',
                'SmartScreen',
                'Unknown publisher|未知发布者',
                'Codex.*安装.*登录|安装.*Codex.*登录',
                '升级.*保留|保留.*升级',
                '保留.*数据|数据.*保留',
                'Build-WindowsInstaller\.ps1 -Configuration Development',
                'outputs\\installer'
            )) {
            $documents | Should -Match $pattern
        }
        $documents | Should -Match '不包含.*凭据|不会.*打包.*凭据'
    }
}

Describe 'adaptive settings center documentation' {
    It 'documents the three implemented pages and immediate theme behavior' {
        $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')

        $readme | Should -Match '外观、行为和中转站'
        $readme | Should -Match '设置中心.*浅色.*深色|浅色.*深色.*设置中心'
        $readme | Should -Match '仅.*完整窗口.*布局'
        $readme | Should -Match '每个中转站.*查询间隔'
        $readme | Should -Not -Match '设置窗口.*全局自动查询间隔'
    }
}

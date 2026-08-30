BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:SkillPath = Join-Path $RepositoryRoot 'skills\codex-quota-monitor\SKILL.md'
    $script:ReadmePath = Join-Path $RepositoryRoot 'README.md'
    $script:SkillContent = if (Test-Path -LiteralPath $SkillPath -PathType Leaf) {
        Get-Content -LiteralPath $SkillPath -Raw
    }
    else {
        ''
    }
    $script:ReadmeContent = if (Test-Path -LiteralPath $ReadmePath -PathType Leaf) {
        Get-Content -LiteralPath $ReadmePath -Raw
    }
    else {
        ''
    }

    function Test-SkillRouteLine {
        param(
            [Parameter(Mandatory)][string]$Content,
            [Parameter(Mandatory)][string]$Intent,
            [Parameter(Mandatory)][string]$ScriptName,
            [Parameter(Mandatory)][bool]$RequireLive
        )

        $normalized = $Content.Replace('\', '/')
        $pattern = '(?mi)^\|\s*{0}\s*\|\s*`[^`\r\n]*-File\s+\./scripts/{1}(?<tail>[^`\r\n]*)`\s*\|\s*$' -f @(
            [regex]::Escape($Intent),
            [regex]::Escape($ScriptName)
        )
        $match = [regex]::Match($normalized, $pattern)
        if (-not $match.Success) {
            return $false
        }

        $hasLive = $match.Groups['tail'].Value -match '(?i)(?:^|\s)-Live(?:\s|$)'
        return $hasLive -eq $RequireLive
    }

    function Test-SkillPolicyContract {
        param([Parameter(Mandatory)][string]$Content)

        $requiredPatterns = @(
            '(?m)^After install, repair, or start, run the ordinary health command\.',
            'After every mutation, run the status command\.',
            '(?m)^When the user expects ChatGPT subscription quota and the account uses supported ChatGPT authentication, additionally run the `-Live` command',
            'Do not require `-Live` for signed-out, API-key-only, Bedrock, or valid zero-window states;',
            '(?m)^Use `-PreserveData` .* only when the user explicitly asks to retain monitor data, settings, or logs\.',
            '(?m)^- Never print credentials, tokens, environment secrets, `auth\.json`, provider headers, raw App Server messages, raw JSON-RPC traffic, or full logs\.\r?$',
            '(?m)^- Closing the floating window \(`Close`\) hides it to the system tray\. Choosing `Exit` from the tray stops monitoring\.\r?$',
            '(?i)decrypted provider JSON',
            '(?i)raw HTTP responses',
            '(?i)request headers',
            '(?i)sidecar stdin/stdout',
            '(?i)CC Switch',
            '管理中转站',
            '(?i)Wakaka.*General.*New API.*Custom',
            '(?i)only after the user enters credentials in the UI'
        )

        foreach ($pattern in $requiredPatterns) {
            if ($Content -notmatch $pattern) {
                return $false
            }
        }

        return $true
    }
}

Describe 'Codex quota monitor management skill contract' {
    It 'exists with valid discoverable YAML frontmatter' {
        Test-Path -LiteralPath $SkillPath -PathType Leaf | Should -BeTrue

        $content = $SkillContent
        $frontmatterMatch = [regex]::Match(
            $content,
            '\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        $frontmatterMatch.Success | Should -BeTrue
        $frontmatter = $frontmatterMatch.Groups['frontmatter'].Value
        $frontmatter | Should -Match '(?m)^name:\s*codex-quota-monitor\s*$'
        $frontmatter | Should -Match '(?m)^description:\s*Use when\s+\S.+'
        $frontmatter.Length | Should -BeLessOrEqual 1024
    }

    It 'contains no unresolved bracketed authoring markers' {
        $content = $SkillContent

        $content | Should -Not -Match '(?i)\[(?:TODO|TBD|PLACEHOLDER|REPLACE[^\]]*)\]'
    }

    It 'routes each intent to the exact command row and live-check mode' -ForEach @(
        @{ Intent = 'install'; ScriptName = 'Install-CodexQuotaMonitor.ps1'; RequireLive = $false },
        @{ Intent = 'show or start'; ScriptName = 'Start-CodexQuotaMonitor.ps1'; RequireLive = $false },
        @{ Intent = 'status'; ScriptName = 'Get-CodexQuotaMonitorStatus.ps1'; RequireLive = $false },
        @{ Intent = 'health or diagnose'; ScriptName = 'Test-CodexQuotaMonitorHealth.ps1'; RequireLive = $false },
        @{ Intent = 'verify ChatGPT quota is live'; ScriptName = 'Test-CodexQuotaMonitorHealth.ps1'; RequireLive = $true },
        @{ Intent = 'repair'; ScriptName = 'Repair-CodexQuotaMonitor.ps1'; RequireLive = $false },
        @{ Intent = 'stop'; ScriptName = 'Stop-CodexQuotaMonitor.ps1'; RequireLive = $false },
        @{ Intent = 'uninstall'; ScriptName = 'Uninstall-CodexQuotaMonitor.ps1'; RequireLive = $false }
    ) {
        Test-SkillRouteLine `
            -Content $SkillContent `
            -Intent $Intent `
            -ScriptName $ScriptName `
            -RequireLive $RequireLive | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $RepositoryRoot "scripts\$ScriptName") -PathType Leaf | Should -BeTrue
    }

    It 'covers exactly the seven thin management scripts' {
        $declared = @(
            'Get-CodexQuotaMonitorStatus.ps1'
            'Install-CodexQuotaMonitor.ps1'
            'Repair-CodexQuotaMonitor.ps1'
            'Start-CodexQuotaMonitor.ps1'
            'Stop-CodexQuotaMonitor.ps1'
            'Test-CodexQuotaMonitorHealth.ps1'
            'Uninstall-CodexQuotaMonitor.ps1'
        ) | Sort-Object
        $normalized = $SkillContent.Replace('\', '/')
        $actual = @(
            [regex]::Matches($normalized, '(?i)\./scripts/(?<name>[A-Za-z0-9-]+\.ps1)') |
                ForEach-Object { $_.Groups['name'].Value } |
                Sort-Object -Unique
        )

        $actual | Should -Be $declared
        foreach ($scriptName in $declared) {
            Test-Path -LiteralPath (Join-Path $RepositoryRoot "scripts\$scriptName") -PathType Leaf |
                Should -BeTrue
        }
    }

    It 'rejects swapped intent-to-script mappings' {
        $tampered = $SkillContent.Replace('Install-CodexQuotaMonitor.ps1', '__INSTALL__')
        $tampered = $tampered.Replace('Uninstall-CodexQuotaMonitor.ps1', 'Install-CodexQuotaMonitor.ps1')
        $tampered = $tampered.Replace('__INSTALL__', 'Uninstall-CodexQuotaMonitor.ps1')

        Test-SkillRouteLine `
            -Content $tampered `
            -Intent 'install' `
            -ScriptName 'Install-CodexQuotaMonitor.ps1' `
            -RequireLive $false | Should -BeFalse
    }

    It 'defines positive mutation, privacy, auth, preserve-data, and close-versus-exit rules' {
        Test-SkillPolicyContract -Content $SkillContent | Should -BeTrue
        $SkillContent | Should -Match 'LastErrorCategory'
        $SkillContent | Should -Match '(?i)API-key-only and Bedrock authentication do not expose ChatGPT quota'
        $SkillContent | Should -Match 'verify the process with ordinary health, then use `-Live` only when ChatGPT quota is expected'
        $SkillContent | Should -Not -Match '(?mi)^(?:After install|\| Starting again immediately after Install \|)[^\r\n]*verify with `-Live`'
    }

    It 'accepts policy lines with CRLF endings' {
        $crlfContent = $SkillContent -replace "(?<!`r)`n", "`r`n"

        Test-SkillPolicyContract -Content $crlfContent | Should -BeTrue
    }

    It 'rejects reversed privacy and account-health policies even when all keywords remain' {
        $unsafe = $SkillContent.Replace('Never print credentials', 'Always print credentials')
        $wrongHealth = $SkillContent.Replace('Do not require `-Live`', 'Require `-Live`')

        Test-SkillPolicyContract -Content $unsafe | Should -BeFalse
        Test-SkillPolicyContract -Content $wrongHealth | Should -BeFalse
    }

    It 'defines relay setup, trust, and sanitized live-verification rules' {
        foreach ($pattern in @(
            'Wakaka', 'General', 'New API', 'Custom', 'Base URL',
            'Test Script', 'Save and enable', 'DPAPI',
            'explicit destination trust', 'api\.wkkapi\.com'
        )) {
            $SkillContent | Should -Match $pattern
        }
        $SkillContent | Should -Match '(?i)never copy credentials from CC Switch'
        $SkillContent | Should -Match '(?i)only after the user enters credentials in the UI'
    }
}

Describe 'Chinese README contract' {
    It 'exists, contains Chinese guidance, and has no authoring markers' {
        Test-Path -LiteralPath $ReadmePath -PathType Leaf | Should -BeTrue
        $ReadmeContent | Should -Match '[\p{IsCJKUnifiedIdeographs}]'
        $ReadmeContent | Should -Not -Match '(?i)\[(?:TODO|TBD|PLACEHOLDER|REPLACE[^\]]*)\]'
    }

    It 'documents every existing thin management script' -ForEach @(
        @{ ScriptName = 'Install-CodexQuotaMonitor.ps1' },
        @{ ScriptName = 'Repair-CodexQuotaMonitor.ps1' },
        @{ ScriptName = 'Start-CodexQuotaMonitor.ps1' },
        @{ ScriptName = 'Stop-CodexQuotaMonitor.ps1' },
        @{ ScriptName = 'Get-CodexQuotaMonitorStatus.ps1' },
        @{ ScriptName = 'Test-CodexQuotaMonitorHealth.ps1' },
        @{ ScriptName = 'Uninstall-CodexQuotaMonitor.ps1' }
    ) {
        $normalized = $ReadmeContent.Replace('\', '/')

        $normalized | Should -Match ([regex]::Escape("./scripts/$ScriptName"))
        Test-Path -LiteralPath (Join-Path $RepositoryRoot "scripts\$ScriptName") -PathType Leaf | Should -BeTrue
    }

    It 'documents ordinary health separately from live quota and explicit data preservation' {
        $normalized = $ReadmeContent.Replace('\', '/')

        $normalized | Should -Match 'Test-CodexQuotaMonitorHealth\.ps1\r?\n'
        $normalized | Should -Match 'Test-CodexQuotaMonitorHealth\.ps1 -Live'
        $normalized | Should -Match 'Uninstall-CodexQuotaMonitor\.ps1 -PreserveData'
        $ReadmeContent | Should -Match '普通健康检查验证程序已安装、正在运行、状态文件有效且足够新；它不要求一定能取得 ChatGPT 额度。'
        $ReadmeContent | Should -Match '仅在账户使用受支持的 ChatGPT 登录且需要验证真实额度时，再运行带 `-Live` 的健康检查'
        $ReadmeContent | Should -Not -Match '优先运行状态命令和带 `-Live` 的健康检查'
    }

    It 'covers UI, account, storage, security, and the official usage dashboard' {
        foreach ($pattern in @(
            '显示/隐藏', '始终置顶', '立即刷新', '开机启动', '查看日志', '退出',
            'AuthRequired', 'Unavailable', 'API key', 'Amazon Bedrock',
            '%LOCALAPPDATA%\\CodexQuotaMonitor\\app',
            '%LOCALAPPDATA%\\CodexQuotaMonitor\\data\\settings\.json',
            '%LOCALAPPDATA%\\CodexQuotaMonitor\\data\\health\.json',
            '%LOCALAPPDATA%\\CodexQuotaMonitor\\logs\\monitor\.log',
            'https://chatgpt\.com/codex/settings/usage',
            '不保存 ChatGPT 访问令牌',
            '关闭到系统托盘'
        )) {
            $ReadmeContent | Should -Match $pattern
        }
    }

    It 'documents relay templates, storage, states, display modes, and privacy boundaries' {
        foreach ($pattern in @(
            '管理中转站', 'Wakaka', 'General', 'New API', 'Custom',
            'Base URL', 'API Key', 'Access Token', 'User ID', 'DPAPI',
            '测试脚本', '保存并启用', '5 分钟', 'Full', 'CompactBar', 'Orb',
            '浅色透明', '深色透明', '关闭到系统托盘', '显式零值',
            'USD', 'CNY', 'Repair', 'PreserveData', '过期'
        )) {
            $ReadmeContent | Should -Match $pattern
        }
        foreach ($pattern in @(
            '不保存.*API key', '不保存.*Access Token', '不保存.*原始 HTTP 响应',
            '不保存.*请求头', '不保存.*sidecar', '不从 CC Switch 自动读取凭据'
        )) {
            $ReadmeContent | Should -Match $pattern
        }
    }
}

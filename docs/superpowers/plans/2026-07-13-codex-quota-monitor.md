# Codex Quota Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, validate, install, and live-check a personal Codex plugin that displays official Codex quota windows in a Windows floating widget and system tray.

**Architecture:** A personal marketplace plugin owns the management skill and PowerShell entry scripts. A PowerShell 7 companion process launches the official `codex app-server` over stdio JSONL, normalizes stable rate-limit responses into presentation records, and drives thin WPF and NotifyIcon adapters. Pure functions and injected adapters keep quota, state-machine, settings, installation, and UI behavior deterministic under Pester; a fake App Server covers process-level integration without requiring live Codex execution inside the agent sandbox.

**Tech Stack:** Codex personal plugins, PowerShell 7.6, WPF, Windows Forms NotifyIcon, Codex App Server JSON-RPC/JSONL, Pester 5.7.1, bundled Python 3.12 plus PyYAML for plugin validation, Git worktrees.

---

## Approved source

- Design: `docs/superpowers/specs/2026-07-12-codex-quota-monitor-design.md`
- Design commit: `39b872e`
- Official protocol: `https://learn.chatgpt.com/docs/app-server`
- Official quota dashboard: `https://chatgpt.com/codex/settings/usage`

## Execution preflight

Use `superpowers:using-git-worktrees` before Task 1. Create branch `feature/codex-quota-monitor` with the worktree at exactly:

`C:\Users\335\plugins\codex-quota-monitor`

That path is both the isolated development worktree and the standard source path referenced by the default personal marketplace. The equivalent Git command, after the skill's safety checks, is:

```powershell
git worktree add -b feature/codex-quota-monitor `
  'C:\Users\335\plugins\codex-quota-monitor' main
```

All paths in the tasks below are relative to that worktree unless an absolute path is shown.

## Locked file map

```text
.codex-plugin/plugin.json                  Plugin manifest
assets/plugin-icon.svg                    Plugin card/logo asset
skills/codex-quota-monitor/SKILL.md       Install/status/repair/uninstall workflow
scripts/Install-CodexQuotaMonitor.ps1     Idempotent user install entry point
scripts/Repair-CodexQuotaMonitor.ps1      Repair entry point
scripts/Start-CodexQuotaMonitor.ps1       Start entry point
scripts/Stop-CodexQuotaMonitor.ps1        Graceful stop entry point
scripts/Get-CodexQuotaMonitorStatus.ps1   Machine-readable status entry point
scripts/Test-CodexQuotaMonitorHealth.ps1  Deterministic/live health entry point
scripts/Uninstall-CodexQuotaMonitor.ps1   User uninstall entry point
companion/CodexQuotaMonitor.psd1          Module manifest and exports
companion/CodexQuotaMonitor.psm1          Focused dot-source composition
companion/Start-CodexQuotaMonitor.ps1     Installed GUI composition root
companion/UI/MainWindow.xaml              Floating-window visual tree
companion/Private/ObjectAccess.ps1         Safe dictionary/PSObject field access
companion/Private/QuotaNormalization.ps1  Official response to quota-window records
companion/Private/Presentation.ps1        Labels, countdowns, colors, tooltip models
companion/Private/JsonRpc.ps1             Message construction and correlation
companion/Private/AppServerProcess.ps1    Child process and JSONL transport
companion/Private/SessionController.ps1   Handshake, auth, refresh, retry state machine
companion/Private/Settings.ps1            Defaults, atomic JSON, corrupt-file recovery
companion/Private/WindowPlacement.ps1      Multi-monitor visible-position clamping
companion/Private/SingleInstance.ps1       Mutex plus activate/exit events
companion/Private/StartupShortcut.ps1      Current-user Startup shortcut functions
companion/Private/Logging.ps1              Sanitized rotating logs
companion/Private/Installation.ps1         Copy, repair, status, start, stop, remove
companion/Private/WpfView.ps1              Thin floating-window adapter
companion/Private/TrayView.ps1             Thin tray/menu adapter and dynamic icons
build/TestRequirements.psd1                Exact Pester dependency pin
build/Restore-TestDependencies.ps1         Repo-local test dependency restore
build/Test.ps1                             Unit/integration/all deterministic runner
tests/Fixtures/FakeAppServer.ps1           Scriptable child-process JSONL server
tests/Fixtures/RateLimits/*.json           Official-shape rate-limit fixtures
tests/Unit/*.Tests.ps1                     Pure behavior tests
tests/Integration/*.Tests.ps1              Process/WPF/tray/install composition tests
tests/Live/AppServer.Live.Tests.ps1        Explicit opt-in live check
README.md                                  Chinese user and recovery guide
```

Do not add `.mcp.json`, `.app.json`, or hook configuration. The companion is a local program managed by the plugin, not an MCP-backed Codex app.

### Task 1: Create the personal plugin scaffold and metadata

**Files:**
- Create: `.codex-plugin/plugin.json`
- Create: `assets/plugin-icon.svg`
- External create/update: `C:\Users\335\.agents\plugins\marketplace.json`

- [ ] **Step 1: Run the official scaffold in the worktree**

```powershell
$Creator = 'C:\Users\335\.codex\skills\.system\plugin-creator'
$Py = 'C:\Users\335\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $Py "$Creator\scripts\create_basic_plugin.py" codex-quota-monitor `
  --path 'C:\Users\335\plugins' `
  --with-skills --with-scripts --with-assets --with-marketplace `
  --marketplace-path 'C:\Users\335\.agents\plugins\marketplace.json'
```

Expected: scaffold path is `C:\Users\335\plugins\codex-quota-monitor`; marketplace root name is `personal`; no `--force` or `--marketplace-name` is used.

- [ ] **Step 2: Replace the scaffold manifest with validated metadata**

```json
{
  "name": "codex-quota-monitor",
  "version": "0.1.0",
  "description": "Install and manage a Windows companion that displays official Codex quota windows.",
  "author": {
    "name": "Local developer"
  },
  "keywords": ["codex", "quota", "windows", "tray", "monitor"],
  "skills": "./skills/",
  "interface": {
    "displayName": "Codex Quota Monitor",
    "shortDescription": "Live Codex quota on the Windows desktop.",
    "longDescription": "Installs, checks, repairs, and removes a Windows tray and floating-window monitor backed by the official Codex App Server.",
    "developerName": "Local developer",
    "category": "Productivity",
    "capabilities": ["Interactive", "Write"],
    "defaultPrompt": [
      "Install and start the Codex quota monitor.",
      "Check the Codex quota monitor status.",
      "Repair or uninstall the Codex quota monitor."
    ],
    "brandColor": "#10A37F",
    "composerIcon": "./assets/plugin-icon.svg",
    "logo": "./assets/plugin-icon.svg"
  }
}
```

- [ ] **Step 3: Add the code-native SVG asset**

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="Codex quota gauge">
  <rect width="128" height="128" rx="28" fill="#101827"/>
  <circle cx="64" cy="64" r="42" fill="none" stroke="#263244" stroke-width="12"/>
  <path d="M64 22a42 42 0 1 1-38.8 58.1" fill="none" stroke="#10A37F" stroke-width="12" stroke-linecap="round"/>
  <path d="m47 51 13 13-13 13M66 78h18" fill="none" stroke="#F7FAFC" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
```

- [ ] **Step 4: Verify the personal marketplace entry without changing it by hand**

```powershell
$market = Get-Content 'C:\Users\335\.agents\plugins\marketplace.json' -Raw | ConvertFrom-Json
$entry = $market.plugins | Where-Object name -eq 'codex-quota-monitor'
if ($market.name -ne 'personal' -or
    $entry.source.path -ne './plugins/codex-quota-monitor' -or
    $entry.policy.installation -ne 'AVAILABLE' -or
    $entry.policy.authentication -ne 'ON_INSTALL') {
  throw 'Personal marketplace entry does not match the approved plugin contract.'
}
```

Expected: no output and exit code 0.

- [ ] **Step 5: Commit the scaffold**

```powershell
git add .codex-plugin/plugin.json assets/plugin-icon.svg
git commit -m "feat: scaffold Codex quota monitor plugin"
```

### Task 2: Add a pinned, repo-local Pester test harness

**Files:**
- Modify: `.gitignore`
- Create: `build/TestRequirements.psd1`
- Create: `build/Restore-TestDependencies.ps1`
- Create: `build/Test.ps1`
- Create: `tests/Unit/Harness.Tests.ps1`

- [ ] **Step 1: Ignore repo-local restored tools and declare the exact test dependency**

Append this one entry to `.gitignore`:

```gitignore
/.tools/
```

```powershell
@{
    PesterVersion = '5.7.1'
    ModuleRoot = '.tools\Modules'
}
```

- [ ] **Step 2: Write the dependency restore script**

```powershell
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$requirements = Import-PowerShellDataFile "$PSScriptRoot\TestRequirements.psd1"
$moduleRoot = Join-Path $root $requirements.ModuleRoot
$manifest = Join-Path $moduleRoot "Pester\$($requirements.PesterVersion)\Pester.psd1"
if (-not (Test-Path -LiteralPath $manifest)) {
    New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
    Save-Module -Name Pester -RequiredVersion $requirements.PesterVersion -Path $moduleRoot -Repository PSGallery
}
Import-Module $manifest -Force
if ((Get-Module Pester).Version.ToString() -ne $requirements.PesterVersion) {
    throw "Expected Pester $($requirements.PesterVersion)."
}
```

- [ ] **Step 3: Write the deterministic suite runner**

```powershell
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Suite = 'All',
    [switch]$CI
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot\Restore-TestDependencies.ps1"
$requirements = Import-PowerShellDataFile "$PSScriptRoot\TestRequirements.psd1"
Import-Module (Join-Path $root "$($requirements.ModuleRoot)\Pester\$($requirements.PesterVersion)\Pester.psd1") -Force
$paths = switch ($Suite) {
    Unit { @((Join-Path $root 'tests\Unit')) }
    Integration { @((Join-Path $root 'tests\Integration')) }
    All { @((Join-Path $root 'tests\Unit'), (Join-Path $root 'tests\Integration')) }
}
$config = New-PesterConfiguration
$config.Run.Path = $paths
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }
$resultDir = Join-Path $root 'outputs\test-results'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'JUnitXml'
$config.TestResult.OutputPath = Join-Path $resultDir "$Suite.xml"
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
```

- [ ] **Step 4: Prove the harness executes the intended PowerShell**

```powershell
Describe 'test harness' {
    It 'runs under PowerShell 7 in STA on Windows' {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 7
        $IsWindows | Should -BeTrue
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -Be 'STA'
    }
}
```

- [ ] **Step 5: Restore and run the unit suite**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit -CI
```

Expected: Pester 5.7.1 is restored under `.tools\Modules`; `FailedCount` is 0.

- [ ] **Step 6: Commit the harness**

```powershell
git add .gitignore build tests/Unit/Harness.Tests.ps1
git commit -m "test: add pinned PowerShell test harness"
```

### Task 3: Normalize official quota responses and presentation records

**Files:**
- Create: `companion/Private/ObjectAccess.ps1`
- Create: `companion/Private/QuotaNormalization.ps1`
- Create: `companion/Private/Presentation.ps1`
- Create: `tests/Fixtures/RateLimits/compatibility-one.json`
- Create: `tests/Fixtures/RateLimits/primary-secondary.json`
- Create: `tests/Fixtures/RateLimits/multi-bucket.json`
- Create: `tests/Fixtures/RateLimits/unknown-window.json`
- Create: `tests/Unit/QuotaNormalization.Tests.ps1`
- Create: `tests/Unit/Presentation.Tests.ps1`

- [ ] **Step 1: Write failing fixture-driven normalization tests**

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1"
    . "$PSScriptRoot\..\..\companion\Private\QuotaNormalization.ps1"
}
Describe 'ConvertTo-QuotaWindow' {
    It 'prefers multi-bucket data and deduplicates compatibility data' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\multi-bucket.json" -Raw | ConvertFrom-Json
        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)
        $rows.Count | Should -Be 3
        @($rows.Key | Select-Object -Unique).Count | Should -Be 3
    }
    It 'clamps remaining percent' -ForEach @(
        @{ Used = $null; Remaining = $null }
        @{ Used = -5; Remaining = 100 }
        @{ Used = 25.5; Remaining = 74.5 }
        @{ Used = 140; Remaining = 0 }
    ) {
        Get-RemainingPercent -UsedPercent $Used | Should -Be $Remaining
    }
}
```

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\QuotaNormalization.Tests.ps1"
```

Expected: FAIL because the three private files do not exist.

- [ ] **Step 2: Implement safe field access and remaining-percent calculation**

```powershell
function Get-ObjectField {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RemainingPercent {
    [CmdletBinding()]
    param([AllowNull()]$UsedPercent)
    if ($null -eq $UsedPercent) { return $null }
    $used = [double]$UsedPercent
    return [Math]::Round([Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $used)), 1)
}
```

- [ ] **Step 3: Implement `ConvertTo-QuotaWindow` with the locked record contract**

Every emitted `PSCustomObject` must have exactly these fields and types:

```powershell
[pscustomobject]@{
    Key                = [string]"$limitId|$windowKind|$duration|$resetsAt"
    LimitId            = [string]$limitId
    LimitName          = [string]$limitName
    WindowKind         = [string]$windowKind
    UsedPercent        = if ($null -eq $used) { $null } else { [double]$used }
    RemainingPercent   = Get-RemainingPercent $used
    WindowDurationMins = [int]$duration
    ResetsAt           = [long]$resetsAt
    RateLimitReached   = [string]$reachedType
}
```

Implementation rules: prefer `rateLimitsByLimitId`; otherwise wrap `rateLimits` under its `limitId` or `codex`; emit non-null `primary` and `secondary`; deduplicate by `Key`; sort by duration then limit id; preserve unknown buckets.

- [ ] **Step 4: Implement pure presentation functions**

```powershell
function Get-QuotaLabel {
    param([Parameter(Mandatory)]$QuotaWindow)
    $minutes = [int]$QuotaWindow.WindowDurationMins
    if ($minutes -ge 270 -and $minutes -le 330) { return '5 小时额度' }
    if ($minutes -ge 9000 -and $minutes -le 11000) { return '周额度' }
    if (-not [string]::IsNullOrWhiteSpace($QuotaWindow.LimitName)) { return $QuotaWindow.LimitName }
    return "其他额度 · $minutes 分钟"
}

function Format-ResetCountdown {
    param([long]$ResetsAt, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $remaining = [datetimeoffset]::FromUnixTimeSeconds($ResetsAt) - $Now
    if ($remaining.TotalSeconds -le 0) { return '正在刷新' }
    if ($remaining.TotalDays -ge 1) { return ('{0}天 {1:00}:{2:00}:{3:00}' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours, $remaining.Minutes, $remaining.Seconds) }
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes, $remaining.Seconds)
}

function Get-QuotaSeverity {
    param([double]$MinimumRemaining, [switch]$Offline)
    if ($Offline) { return 'Gray' }
    if ($MinimumRemaining -lt 15) { return 'Red' }
    if ($MinimumRemaining -le 40) { return 'Yellow' }
    return 'Green'
}
```

Add `Get-TrayTooltip` that returns at most 63 characters and uses `5h`, `周`, or the official/other label plus rounded remaining percentage.

- [ ] **Step 5: Run both focused suites**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\QuotaNormalization.Tests.ps1, .\tests\Unit\Presentation.Tests.ps1"
```

Expected: all normalization, labeling, countdown, threshold, and tooltip cases pass.

- [ ] **Step 6: Commit**

```powershell
git add companion/Private tests/Fixtures/RateLimits tests/Unit/QuotaNormalization.Tests.ps1 tests/Unit/Presentation.Tests.ps1
git commit -m "feat: normalize and present Codex quota windows"
```

### Task 4: Implement JSON-RPC messages and the session state machine

**Files:**
- Create: `companion/Private/JsonRpc.ps1`
- Create: `companion/Private/SessionController.ps1`
- Create: `tests/Unit/JsonRpc.Tests.ps1`
- Create: `tests/Unit/SessionController.Tests.ps1`

- [ ] **Step 1: Write failing protocol-order tests**

```powershell
Describe 'Codex App Server session controller' {
    It 'starts with initialize and waits for its response' {
        $state = New-SessionState
        $actions = @(Start-SessionHandshake -State $state)
        $actions.Count | Should -Be 1
        $actions[0].Method | Should -Be 'initialize'
        $actions[0].Params.clientInfo.name | Should -Be 'codex_quota_monitor'
    }
    It 'acknowledges initialization then reads account and quota' {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]
        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{ id = $init.Id; result = @{} }))
        $actions.Method | Should -Be @('initialized', 'account/read', 'account/rateLimits/read')
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'Params'
        $actions[1].Params.Keys.Count | Should -Be 0
        $actions[2].PSObject.Properties.Name | Should -Not -Contain 'Params'
    }
    It 'coalesces an update notification into one full quota read' {
        $state = New-SessionState
        $state.Initialized = $true
        $message = [pscustomobject]@{ method = 'account/rateLimits/updated'; params = @{} }
        @(Update-SessionFromMessage -State $state -Message $message).Method | Should -Be @('account/rateLimits/read')
        @(Update-SessionFromMessage -State $state -Message $message).Count | Should -Be 0
    }
}
```

Expected initial run: FAIL because the controller functions do not exist.

- [ ] **Step 2: Implement message constructors with no `jsonrpc` field**

```powershell
function New-RpcRequest {
    param([int]$Id, [string]$Method, [AllowNull()]$Params)
    $message = [ordered]@{ method = $Method; id = $Id }
    if ($null -ne $Params) { $message.params = $Params }
    return [pscustomobject]$message
}

function New-RpcNotification {
    param([string]$Method, [AllowNull()]$Params)
    $message = [ordered]@{ method = $Method }
    if ($null -ne $Params) { $message.params = $Params }
    return [pscustomobject]$message
}

function ConvertTo-JsonLine {
    param([Parameter(Mandatory)]$Message)
    return (($Message | ConvertTo-Json -Depth 20 -Compress) + "`n")
}
```

- [ ] **Step 3: Implement the session state and exact stable handshake**

`New-SessionState` returns a mutable record with `NextId`, `Pending`, `Initialized`, `QuotaReadPending`, `Status`, `PlanType`, `QuotaWindows`, `LastSuccessAt`, `LastError`, and `ReconnectAttempt`.

The first request is:

```powershell
New-RpcRequest -Id $id -Method 'initialize' -Params ([ordered]@{
    clientInfo = [ordered]@{
        name = 'codex_quota_monitor'
        title = 'Codex Quota Monitor'
        version = '0.1.0'
    }
})
```

After its successful response, emit in order:

```powershell
New-RpcNotification -Method 'initialized' -Params $null
New-RpcRequest -Id $accountId -Method 'account/read' -Params @{}
New-RpcRequest -Id $quotaId -Method 'account/rateLimits/read' -Params $null
```

Known `apiKey` accounts transition to `AuthRequired` with a message that API billing is distinct from ChatGPT quota. A null account with `requiresOpenaiAuth = true` transitions to `AuthRequired`. A null account with `requiresOpenaiAuth = false` and `amazonBedrock` accounts transition to `Unavailable` because ChatGPT quota is not applicable. Other ChatGPT-backed authenticated types may attempt the quota read. A successful quota response calls `ConvertTo-QuotaWindow`, sets `Live`, clears retry state, and records UTC success time. `account/updated` invalidates the account snapshot and emits a fresh `account/read`; if the refreshed account is no longer ChatGPT-backed, clear quota rows rather than retaining stale account data.

- [ ] **Step 4: Add deterministic retry and timeout functions**

```powershell
function Get-ReconnectDelaySeconds {
    param([ValidateRange(0, 1000)][int]$Attempt)
    $schedule = @(2, 5, 15, 30, 60)
    return $schedule[[Math]::Min($Attempt, $schedule.Count - 1)]
}

function Test-RequestExpired {
    param([datetimeoffset]$SentAt, [datetimeoffset]$Now, [int]$TimeoutSeconds = 10)
    return (($Now - $SentAt).TotalSeconds -ge $TimeoutSeconds)
}
```

- [ ] **Step 5: Run focused protocol tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\JsonRpc.Tests.ps1, .\tests\Unit\SessionController.Tests.ps1"
git add companion/Private/JsonRpc.ps1 companion/Private/SessionController.ps1 tests/Unit
git commit -m "feat: add Codex App Server session protocol"
```

Expected: exact handshake ordering, auth states, full refresh, timeout, and `2,5,15,30,60` retry tests pass.

### Task 5: Add the redirected App Server process transport

**Files:**
- Create: `companion/Private/AppServerProcess.ps1`
- Create: `tests/Fixtures/FakeAppServer.ps1`
- Create: `tests/Integration/AppServerProcess.Tests.ps1`

- [ ] **Step 1: Write a fake JSONL server and failing process test**

The fake server reads compact JSON lines from stdin and implements these deterministic responses:

```powershell
param([ValidateSet('Happy', 'Malformed', 'ExitAfterInitialize')][string]$Scenario = 'Happy')
$ErrorActionPreference = 'Stop'
while (($line = [Console]::In.ReadLine()) -ne $null) {
    if ($Scenario -eq 'Malformed') { [Console]::Out.WriteLine('{broken'); [Console]::Out.Flush(); continue }
    $message = $line | ConvertFrom-Json
    switch ($message.method) {
        initialize {
            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ userAgent = 'fake'; platformFamily = 'windows'; platformOs = 'windows' } } | ConvertTo-Json -Compress))
            [Console]::Out.Flush()
            if ($Scenario -eq 'ExitAfterInitialize') { exit 17 }
        }
        'account/read' {
            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ account = @{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true } } | ConvertTo-Json -Depth 8 -Compress))
            [Console]::Out.Flush()
        }
        'account/rateLimits/read' {
            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ rateLimits = @{ limitId = 'codex'; primary = @{ usedPercent = 25; windowDurationMins = 300; resetsAt = 1893456000 }; secondary = @{ usedPercent = 40; windowDurationMins = 10080; resetsAt = 1893888000 } } } } | ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.Flush()
        }
    }
}
```

The integration test starts the fake via the stable `C:\Users\335\AppData\Local\Microsoft\WindowsApps\pwsh.exe` alias and verifies that one initialize request produces one correlated response.

Expected initial run: FAIL because the process transport does not exist.

- [ ] **Step 2: Implement process start with `ProcessStartInfo.ArgumentList`**

`Start-AppServerProcess` accepts `-ExecutablePath`, `-ArgumentList`, and optional `-WorkingDirectory`. It sets `UseShellExecute = $false`, redirects stdin/stdout/stderr, hides the window, and starts asynchronous line reads. Do not concatenate or shell-escape an argument string.

Store stdout/stderr records in bounded `ConcurrentQueue[object]` instances and expose:

```powershell
function Receive-AppServerRecord {
    param([Parameter(Mandatory)]$Transport, [int]$Maximum = 100)
    $records = [Collections.Generic.List[object]]::new()
    $record = $null
    while ($records.Count -lt $Maximum -and $Transport.Queue.TryDequeue([ref]$record)) {
        $records.Add($record)
    }
    return $records
}
```

Each record has `Stream`, `Line`, and `ReceivedAt`. JSON parsing happens when the WPF dispatcher drains the queue, never inside a process callback. Keep at most 1,000 stdout records and 200 redacted stderr records so a noisy child cannot grow memory without bound.

- [ ] **Step 3: Implement safe discovery and shutdown**

`Find-CodexExecutable` checks, in order:

1. `Get-Command codex.exe` or `Get-Command codex`;
2. `Get-AppxPackage -Name OpenAI.Codex` plus `app\resources\codex.exe`;
3. returns a structured `Missing` result.

`Start-AppServerProcess` converts `UnauthorizedAccessException`, `Win32Exception` access denied, and missing-file failures into distinct sanitized error categories. `Stop-AppServerProcess` closes stdin, waits two seconds, then kills only its own still-running child process tree.

- [ ] **Step 4: Run process integration tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\AppServerProcess.Tests.ps1"
git add companion/Private/AppServerProcess.ps1 tests/Fixtures/FakeAppServer.ps1 tests/Integration/AppServerProcess.Tests.ps1
git commit -m "feat: add App Server JSONL process transport"
```

Expected: happy response, Unicode/space argument handling, malformed-line record, child exit, and owned-child cleanup cases pass.

### Task 6: Persist settings, clamp window placement, and rotate sanitized logs

**Files:**
- Create: `companion/Private/Settings.ps1`
- Create: `companion/Private/WindowPlacement.ps1`
- Create: `companion/Private/Logging.ps1`
- Create: `tests/Unit/Settings.Tests.ps1`
- Create: `tests/Unit/WindowPlacement.Tests.ps1`
- Create: `tests/Unit/Logging.Tests.ps1`

- [ ] **Step 1: Write failing tests using Pester `$TestDrive`**

Cover default `{ Topmost = true; Visible = true }`, atomic round-trip, corrupt JSON rename, off-screen recovery against injected work areas, and log rotation at an injected 1 KB threshold. Assert sanitized logs never contain values from fields named `accessToken`, `authorization`, `email`, or complete raw JSONL.

- [ ] **Step 2: Implement default paths and settings**

```powershell
function Get-MonitorPaths {
    param([string]$LocalAppData = $env:LOCALAPPDATA, [string]$Startup = [Environment]::GetFolderPath('Startup'))
    $root = Join-Path $LocalAppData 'CodexQuotaMonitor'
    [pscustomobject]@{
        Root = $root
        App = Join-Path $root 'app'
        Data = Join-Path $root 'data'
        Logs = Join-Path $root 'logs'
        Settings = Join-Path $root 'data\settings.json'
        Health = Join-Path $root 'data\health.json'
        StartupShortcut = Join-Path $Startup 'Codex Quota Monitor.lnk'
    }
}

function New-DefaultSettings {
    [ordered]@{ SchemaVersion = 1; Window = [ordered]@{ Left = $null; Top = $null; Topmost = $true; Visible = $true }; Startup = $true }
}
```

Write JSON to a sibling temporary file, flush it, then replace the settings file. On parse failure, rename the corrupt file with a UTC timestamp suffix and return defaults.

- [ ] **Step 3: Implement pure work-area clamping**

`Resolve-WindowPlacement` accepts saved left/top, window width/height, and an array of `{ Left, Top, Width, Height }` work areas. Keep at least 48 logical pixels of the title area visible. If no area intersects, return a position 24 pixels inside the nearest primary work area.

- [ ] **Step 4: Implement sanitized rotating logs**

`Write-MonitorLog` accepts only `Level`, `Event`, and a flat sanitized `Data` dictionary. Reject keys matching `token|authorization|cookie|email|raw` case-insensitively. Rotate `monitor.log` through `monitor.1.log` to `monitor.5.log` before the next write would exceed 1 MB in production; tests inject a smaller threshold.

- [ ] **Step 5: Run focused tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\Settings.Tests.ps1, .\tests\Unit\WindowPlacement.Tests.ps1, .\tests\Unit\Logging.Tests.ps1"
git add companion/Private tests/Unit
git commit -m "feat: persist monitor settings and sanitized logs"
```

### Task 7: Add single-instance control and current-user startup helpers

**Files:**
- Create: `companion/Private/SingleInstance.ps1`
- Create: `companion/Private/StartupShortcut.ps1`
- Create: `tests/Integration/SingleInstance.Tests.ps1`
- Create: `tests/Integration/StartupShortcut.Tests.ps1`

- [ ] **Step 1: Write failing GUID-isolated lifecycle tests**

Create two instance handles with a unique `Local\CodexQuotaMonitor.Tests.<guid>` prefix. Assert the first is primary, the second is secondary, `Activate` wakes the primary event, and `Exit` wakes the exit event. Shortcut tests create a real `.lnk` under `$TestDrive`, reopen it through `WScript.Shell`, and assert target, arguments, and working directory.

- [ ] **Step 2: Implement mutex and event ownership**

`Enter-MonitorInstance` returns:

```powershell
[pscustomobject]@{
    IsPrimary = [bool]$createdNew
    Mutex = $mutex
    ActivateEvent = $activateEvent
    ExitEvent = $exitEvent
    Prefix = $Prefix
}
```

The primary creates `EventWaitHandle` instances named `<prefix>.Activate` and `<prefix>.Exit` with `AutoReset`. A secondary opens and sets the requested event, disposes its handles, and exits. `Close-MonitorInstance` disposes all handles and releases the mutex only when owned.

- [ ] **Step 3: Implement the stable PowerShell alias probe and shortcut**

Probe `C:\Users\335\AppData\Local\Microsoft\WindowsApps\pwsh.exe` first by running `-NoLogo -NoProfile -Command exit 0`; fall back to `Get-Command pwsh`. Create the shortcut with:

```powershell
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $PwshPath
$shortcut.Arguments = "-NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File `"$EntryScript`""
$shortcut.WorkingDirectory = Split-Path $EntryScript -Parent
$shortcut.Description = 'Codex quota monitor'
$shortcut.Save()
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
```

Do not use `-ExecutionPolicy Bypass`.

- [ ] **Step 4: Run integration tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\SingleInstance.Tests.ps1, .\tests\Integration\StartupShortcut.Tests.ps1"
git add companion/Private tests/Integration
git commit -m "feat: add monitor lifecycle and startup primitives"
```

### Task 8: Build the WPF floating-window adapter

**Files:**
- Create: `companion/UI/MainWindow.xaml`
- Create: `companion/Private/WpfView.ps1`
- Create: `tests/Integration/WpfComposition.Tests.ps1`

- [ ] **Step 1: Write a failing STA composition test**

Load the XAML without showing it. Assert named controls `RootBorder`, `HeaderDragArea`, `ConnectionDot`, `TitleText`, `PinButton`, `HideButton`, `CloseButton`, `QuotaRows`, and `FreshnessText` exist. Apply a two-row presentation model, assert two child cards, toggle topmost, then close and release the view.

- [ ] **Step 2: Create the complete visual tree**

The XAML window must use `WindowStyle="None"`, `AllowsTransparency="True"`, `Background="Transparent"`, `Width="300"`, `SizeToContent="Height"`, `Topmost="True"`, `ShowInTaskbar="False"`, and a minimum height of 150. `RootBorder` uses a dark `#EE101827` background, corner radius 16, and padding 12. The header is a 28-pixel grid with a draggable area, green/gray connection dot, title, pin, hide, and close buttons. `QuotaRows` is a vertical StackPanel. `FreshnessText` is collapsed while live and visible when stale.

- [ ] **Step 3: Implement the thin view adapter**

`New-QuotaWindowView` loads XAML through `XamlReader`, resolves all named elements, attaches no business logic, and returns methods/scriptblocks named `Show`, `Hide`, `Activate`, `SetTopmost`, `Render`, `SetFreshness`, `GetPlacement`, and `Dispose`.

`Render` rebuilds quota cards with label, large remaining percentage, a remaining-quota ProgressBar, countdown, and reset local time. All values come from presentation records; the adapter performs no rate-limit calculations.

- [ ] **Step 4: Wire view-only events**

Expose callbacks `OnDrag`, `OnToggleTopmost`, `OnHide`, and `OnCloseRequested`. Closing cancels the WPF close and delegates to hide unless the composition root has set `AllowExit = true`.

- [ ] **Step 5: Run the WPF composition test and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\WpfComposition.Tests.ps1"
git add companion/UI companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
git commit -m "feat: add Codex quota floating window"
```

Expected: XAML loads and measures without displaying a window; no UI automation or coordinate sleeps are used.

### Task 9: Build the tray adapter and interaction controller

**Files:**
- Create: `companion/Private/TrayView.ps1`
- Create: `tests/Unit/InteractionController.Tests.ps1`
- Create: `tests/Integration/TrayComposition.Tests.ps1`

- [ ] **Step 1: Write failing pure interaction tests**

Using fake window and tray adapters, verify: tray double-click toggles visibility; Close hides; Exit sets the exit event; pin changes both adapters and persists settings; manual refresh emits one quota read; startup toggle calls the shortcut adapter once.

- [ ] **Step 2: Implement reusable in-memory tray icons**

Create four 32-by-32 `System.Drawing.Bitmap` objects once. Draw a dark circular base and a green, yellow, red, or gray gauge arc. Convert each bitmap to `System.Drawing.Icon`, retain the backing bitmap and native icon handle for the process lifetime, and dispose/release all resources exactly once at exit.

- [ ] **Step 3: Implement the tray menu contract**

`New-TrayView -Visible:$false` returns a NotifyIcon adapter with menu items in this order:

```text
显示/隐藏
始终置顶
立即刷新
开机启动
打开官方额度页面
查看日志
退出
```

The dashboard item opens `https://chatgpt.com/codex/settings/usage`. The log item opens the monitor log directory. Tooltip text is truncated to the Windows-safe 63-character bound. Tests keep `NotifyIcon.Visible = $false`.

- [ ] **Step 4: Run controller and tray tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\InteractionController.Tests.ps1, .\tests\Integration\TrayComposition.Tests.ps1"
git add companion/Private/TrayView.ps1 tests/Unit/InteractionController.Tests.ps1 tests/Integration/TrayComposition.Tests.ps1
git commit -m "feat: add Codex quota tray controls"
```

### Task 10: Compose the production monitor and deterministic headless integration

**Files:**
- Create: `companion/CodexQuotaMonitor.psd1`
- Create: `companion/CodexQuotaMonitor.psm1`
- Create: `companion/Start-CodexQuotaMonitor.ps1`
- Create: `tests/Integration/MonitorRuntime.Tests.ps1`

- [ ] **Step 1: Write a failing end-to-end fake-server test**

Start the composition root with `-Headless`, the fake server executable/arguments, a `$TestDrive` local-app-data root, and `-RunForSeconds 3`. Assert the health JSON reaches `Live`, contains two quota windows, reports plan `plus`, and records no secret-bearing raw message.

- [ ] **Step 2: Create the module manifest and explicit exports**

Export only:

```powershell
FunctionsToExport = @(
    'Install-CodexQuotaMonitor',
    'Repair-CodexQuotaMonitor',
    'Uninstall-CodexQuotaMonitor',
    'Start-CodexQuotaMonitor',
    'Stop-CodexQuotaMonitor',
    'Get-CodexQuotaMonitorStatus',
    'Test-CodexQuotaMonitorHealth'
)
```

Set `RootModule = 'CodexQuotaMonitor.psm1'`, `ModuleVersion = '0.1.0'`, `PowerShellVersion = '7.4'`, and a fixed GUID generated once for this module.

- [ ] **Step 3: Dot-source private files in dependency order**

`CodexQuotaMonitor.psm1` loads: ObjectAccess, QuotaNormalization, Presentation, JsonRpc, Settings, WindowPlacement, Logging, AppServerProcess, SessionController, SingleInstance, StartupShortcut, WpfView, TrayView, and Installation. It then exports only the seven public functions.

- [ ] **Step 4: Implement the composition loop**

The production root:

- enters the single-instance handle;
- loads settings and creates views unless `-Headless`;
- starts `codex app-server` with argument `app-server`;
- sends one initialize request and drains transport records on a 100 ms WPF DispatcherTimer;
- advances countdowns every second;
- requests a defensive full refresh every 60 seconds;
- requests immediately on `account/rateLimits/updated`, reset time, manual refresh, and system resume;
- requests `account/read` on `account/updated` and clears quota if authentication is no longer ChatGPT-backed;
- uses the `2,5,15,30,60` reconnect schedule after EOF or timeout;
- writes health JSON atomically on state transitions;
- observes named Activate and Exit events;
- removes the `SystemEvents.PowerModeChanged` handler and disposes child process, WPF, tray, mutex/events, bitmaps, and icons in `finally`.

On every child restart, discard all pending request IDs and run the complete initialization handshake before reading account or quota. Treat `account/rateLimits/updated` as a sparse invalidation only; never overwrite the full multi-bucket snapshot directly from that notification.

Register resume with a retained `[Microsoft.Win32.PowerModeChangedEventHandler]` delegate and remove the same delegate at exit.

- [ ] **Step 5: Run deterministic runtime integration and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\MonitorRuntime.Tests.ps1"
git add companion tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: compose the Codex quota monitor runtime"
```

### Task 11: Add idempotent install, repair, status, start, stop, and uninstall

**Files:**
- Create: `companion/Private/Installation.ps1`
- Create: `scripts/Install-CodexQuotaMonitor.ps1`
- Create: `scripts/Repair-CodexQuotaMonitor.ps1`
- Create: `scripts/Start-CodexQuotaMonitor.ps1`
- Create: `scripts/Stop-CodexQuotaMonitor.ps1`
- Create: `scripts/Get-CodexQuotaMonitorStatus.ps1`
- Create: `scripts/Test-CodexQuotaMonitorHealth.ps1`
- Create: `scripts/Uninstall-CodexQuotaMonitor.ps1`
- Create: `tests/Integration/Installation.Tests.ps1`

- [ ] **Step 1: Write failing isolated installation tests**

Inject `$TestDrive\LocalAppData` and `$TestDrive\Startup`. Assert first install and repeated install produce the same file set and one shortcut; repair preserves settings; stop signals only the named monitor event; uninstall removes runtime and shortcut; `-PreserveData` retains `data` and `logs` only.

- [ ] **Step 2: Implement staged publishing and health state**

`Install-CodexQuotaMonitor` validates PowerShell 7 plus WPF/Forms assembly loading, signals an existing monitor to exit, copies `companion` to `<root>\app.new`, replaces `<root>\app`, creates the shortcut, starts the stable pwsh alias hidden, and waits up to 15 seconds for `health.json`. Runtime replacement never deletes `data` or `logs`.

Health JSON fields are fixed:

```powershell
[ordered]@{
    SchemaVersion = 1
    Status = 'Starting'
    PlanType = $null
    QuotaWindowCount = 0
    LastSuccessAt = $null
    LastErrorCategory = $null
    LastErrorMessage = $null
    ProcessId = $PID
    UpdatedAt = [datetimeoffset]::UtcNow.ToString('o')
}
```

- [ ] **Step 3: Implement thin plugin entry scripts**

Each script sets `$ErrorActionPreference = 'Stop'`, imports `..\companion\CodexQuotaMonitor.psd1`, and calls exactly one exported function. `Uninstall` exposes `[switch]$PreserveData`; health exposes `[switch]$Live`; status returns one object and supports JSON via normal PowerShell piping.

- [ ] **Step 4: Run installation tests and commit**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\Installation.Tests.ps1"
git add companion/Private/Installation.ps1 scripts tests/Integration/Installation.Tests.ps1
git commit -m "feat: add quota monitor installation lifecycle"
```

### Task 12: Add the Codex management skill and Chinese documentation

**Required sub-skill:** Use `writing-skills` for this task.

**Files:**
- Create: `skills/codex-quota-monitor/SKILL.md`
- Create: `README.md`
- Create: `tests/Unit/SkillContract.Tests.ps1`

- [ ] **Step 1: Write a failing skill contract test**

Assert the skill has valid YAML frontmatter with `name: codex-quota-monitor`, a nonempty description, no unresolved bracketed marker, and explicit routing for install, status, repair, start, stop, and uninstall scripts.

- [ ] **Step 2: Write the skill workflow**

The skill must:

- trigger when the user asks to install, show, start, stop, repair, diagnose, or remove the quota monitor;
- run the matching script instead of giving generic instructions;
- report health state and sanitized error category after mutations;
- never expose credentials or print raw App Server messages;
- explain that API-key-only/Bedrock auth does not expose ChatGPT quota;
- use `-PreserveData` only when the user explicitly asks to keep settings/logs;
- tell the user that Close hides to tray and Exit stops monitoring.

- [ ] **Step 3: Write the Chinese README**

Cover installation, floating-window controls, tray colors/menu, auto-start, data source, files written under LocalAppData, status/repair/uninstall commands, signed-out/API-key states, logs, security boundary, and the official dashboard link. Include the exact commands from `scripts` and no unsupported claims.

- [ ] **Step 4: Run skill and documentation checks**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\SkillContract.Tests.ps1"
```

Expected: skill contract passes.

- [ ] **Step 5: Commit**

```powershell
git add skills README.md tests/Unit/SkillContract.Tests.ps1
git commit -m "docs: add quota monitor skill and user guide"
```

### Task 13: Run full verification, install the companion, and install the plugin

**Files:**
- Modify only if verification reveals a defect in a file already listed above.
- External create/update: `%LOCALAPPDATA%\CodexQuotaMonitor\**`
- External create/update: current-user Startup shortcut
- External create/update: Codex installed-plugin state

- [ ] **Step 1: Parse-check every PowerShell source file**

```powershell
$errors = @()
Get-ChildItem companion,scripts,build,tests -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    $errors += $parseErrors
}
if ($errors.Count) { $errors | Format-List; exit 1 }
```

Expected: exit code 0 and no parse errors.

- [ ] **Step 2: Run all deterministic tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
```

Expected: `FailedCount` is 0; JUnit XML exists under ignored `outputs\test-results`.

- [ ] **Step 3: Bootstrap plugin-validator YAML locally and validate**

```powershell
$Creator = 'C:\Users\335\.codex\skills\.system\plugin-creator'
$Py = 'C:\Users\335\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$pyDeps = Join-Path $PWD 'work\plugin-validator'
& $Py -m pip install --disable-pip-version-check --target $pyDeps 'PyYAML>=6,<7'
$env:PYTHONPATH = $pyDeps
& $Py "$Creator\scripts\validate_plugin.py" $PWD
```

Expected: `Plugin validation passed: C:\Users\335\plugins\codex-quota-monitor`.

- [ ] **Step 4: Validate the skill with the skill-creator checker**

```powershell
& $Py 'C:\Users\335\.codex\skills\.system\skill-creator\scripts\quick_validate.py' `
  '.\skills\codex-quota-monitor'
```

Expected: exit code 0.

- [ ] **Step 5: Install and start the desktop companion**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1 | Format-List
```

Expected outside the Codex sandbox: one running monitor, one Startup shortcut, and health `Live` with at least one quota window when the current Codex account uses supported ChatGPT authentication.

- [ ] **Step 6: Perform the normal-desktop smoke check**

Because packaged `codex.exe` currently returns Access Denied inside the Codex agent shell, use the `computer-use` skill to launch Step 5 in a normal desktop PowerShell session. Verify the floating window appears, the tray icon exists, Show/Hide works, always-on-top toggles, Close hides, and Exit stops the process. Relaunch after Exit so monitoring remains installed.

- [ ] **Step 7: Install the plugin from the default personal marketplace**

```powershell
$MarketplaceName = & $Py "$Creator\scripts\read_marketplace_name.py"
codex plugin add "codex-quota-monitor@$MarketplaceName"
```

Expected outside the sandbox: plugin installation succeeds. Do not run `codex plugin marketplace add`; the default personal marketplace is discovered implicitly.

- [ ] **Step 8: Record final evidence and commit any verification-only correction**

```powershell
git status --short
git log --oneline --decorate -12
```

If verification required a correction after the plugin was installed, add only the affected files, rerun Steps 1-4, commit with a focused `fix:` message, run `update_plugin_cachebuster.py`, validate again, and reinstall from the `personal` marketplace. Finish with a clean worktree. Then use `verification-before-completion`, `requesting-code-review`, and `finishing-a-development-branch` before claiming completion.

Because the personal marketplace was created or updated, the final handoff must include these two Codex app links:

```text
codex://plugins/codex-quota-monitor?marketplacePath=C%3A%5CUsers%5C335%5C.agents%5Cplugins%5Cmarketplace.json
codex://plugins/codex-quota-monitor?marketplacePath=C%3A%5CUsers%5C335%5C.agents%5Cplugins%5Cmarketplace.json&mode=share
```

## Acceptance evidence map

- Plugin schema and marketplace: Tasks 1 and 13.
- Official quota parsing and countdowns: Task 3.
- Stable App Server handshake and update refresh: Tasks 4 and 5.
- Settings, stale state, logs, and off-screen recovery: Task 6.
- Single instance and current-user auto-start: Tasks 7 and 11.
- Floating window and topmost switching: Task 8.
- Tray colors, menu, hide, refresh, and exit: Task 9.
- Reconnect, 60-second poll, resume, reset refresh, and health: Task 10.
- Idempotent install/repair/uninstall: Task 11.
- Codex-operable workflow and user instructions: Task 12.
- Deterministic, plugin, skill, and live desktop verification: Task 13.

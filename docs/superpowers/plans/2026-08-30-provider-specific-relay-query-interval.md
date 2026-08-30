# 中转站独立查询间隔 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除设置窗口中的全局查询间隔，让每个中转站按自己的 `IntervalMinutes` 独立调度，并把所有新建和首次导入的默认值统一为 5 分钟。

**Architecture:** 保留 provider schema 2 中现有的 `IntervalMinutes` 作为唯一运行时调度来源；设置 schema 3 中的 `Relay.AutoQueryIntervalMinutes` 仅作向后兼容，不再接入 UI 或运行时。调度器、运行时组合、管理器草稿、CC Switch 导入和预设分别通过现有边界调整，不新增共享状态或迁移已有 provider 文件。

**Tech Stack:** PowerShell 7.4+、WPF/XAML、Pester 5.7.1、JSON provider/settings 配置。

---

### Task 1: 恢复 provider 独立调度

**Files:**
- Modify: `tests/Unit/RelayScheduler.Tests.ps1`
- Modify: `companion/Private/RelayScheduler.ps1`

- [ ] **Step 1: 写入失败的 provider 间隔测试**

将全局覆盖相关用例替换为以下行为测试，并把成功后的下一次调度用例改为只传 provider 自身的 `IntervalMinutes = 17`：

```powershell
It 'uses each provider interval without a global override' {
    $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
    $scheduler = New-RelaySchedulerState -Providers @(
        New-TestRelaySchedulerProvider 'one' -IntervalMinutes 3
        New-TestRelaySchedulerProvider 'two' -IntervalMinutes 17
    ) -Now $now

    $automatic = Get-RelaySchedulerActions -State $scheduler -Now $now

    @($scheduler.Providers | Select-Object -ExpandProperty IntervalMinutes) |
        Should -Be @(3, 17)
    @($automatic.Actions | Select-Object -ExpandProperty ProviderId) |
        Should -Be @('one', 'two')
}

It 'keeps only a zero-interval provider manual-only' {
    $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
    $providers = @(
        New-TestRelaySchedulerProvider 'disabled' -Enabled $false -IntervalMinutes 5
        New-TestRelaySchedulerProvider 'manual' -IntervalMinutes 0
        New-TestRelaySchedulerProvider 'automatic' -IntervalMinutes 20
    )
    $scheduler = New-RelaySchedulerState -Providers $providers -Now $now

    $automatic = Get-RelaySchedulerActions -State $scheduler -Now $now
    $manual = Get-RelaySchedulerActions `
        -State (New-RelaySchedulerState -Providers $providers -Now $now) `
        -Now $now -ManualRefresh

    @($scheduler.Providers | Select-Object -ExpandProperty IntervalMinutes) |
        Should -Be @(5, 0, 20)
    @($scheduler.Providers | Select-Object -ExpandProperty NextDueAt) |
        Should -Be @([DateTimeOffset]::MaxValue, [DateTimeOffset]::MaxValue, $now)
    @($automatic.Actions | Select-Object -ExpandProperty ProviderId) |
        Should -Be @('automatic')
    @($manual.Actions | Select-Object -ExpandProperty ProviderId) |
        Should -Be @('manual', 'automatic')
}

It 'rejects an out-of-range provider interval' -ForEach @(
    @{ Value = -1 }
    @{ Value = 1441 }
) {
    {
        New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk' -IntervalMinutes $Value
        )
    } | Should -Throw -ExpectedMessage '*between 0 and 1440*'
}
```

- [ ] **Step 2: 运行调度器测试并确认失败原因**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { . .\build\Restore-TestDependencies.ps1; `$r = Invoke-Pester -Path .\tests\Unit\RelayScheduler.Tests.ps1 -Output Detailed -PassThru; if (`$r.Result -ne 'Passed') { exit 1 } }"
```

Expected: FAIL，因为当前调度器仍把所有 entry 改成全局默认值 10，且不按 provider 的零值进入手动模式。

- [ ] **Step 3: 最小实现 provider 间隔读取**

把 `New-RelaySchedulerState` 的参数和循环改为：

```powershell
function New-RelaySchedulerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Providers,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [ValidateRange(1, 16)][int]$MaximumConcurrency = 2
    )
    $nowUtc = $Now.ToUniversalTime()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($provider in @($Providers)) {
        $providerId = [string](Get-RelaySchedulerValue $provider 'Id')
        $enabled = [bool](Get-RelaySchedulerValue $provider 'Enabled')
        $interval = [int](Get-RelaySchedulerValue $provider 'IntervalMinutes')
        if ([string]::IsNullOrWhiteSpace($providerId) -or -not $seen.Add($providerId)) {
            throw [ArgumentException]::new('Relay scheduler provider is invalid.')
        }
        if ($interval -lt 0 -or $interval -gt 1440) {
            throw [ArgumentOutOfRangeException]::new(
                'IntervalMinutes',
                'Relay provider interval must be between 0 and 1440 minutes.'
            )
        }
        $nextDueAt = if ($enabled -and $interval -gt 0) {
            $nowUtc
        }
        else {
            [DateTimeOffset]::MaxValue
        }
        $pauseReason = if ($enabled) { $null } else { 'Disabled' }
        $entries.Add((New-RelaySchedulerProviderEntry -ProviderId $providerId `
            -Enabled $enabled -IntervalMinutes $interval -InFlight $false `
            -NextDueAt $nextDueAt -ConsecutiveFailures 0 -PauseReason $pauseReason))
    }
    New-RelaySchedulerStateObject -MaximumConcurrency $MaximumConcurrency `
        -Providers ([object[]]$entries.ToArray())
}
```

- [ ] **Step 4: 运行调度器测试并确认通过**

Run the Step 2 command.

Expected: PASS，所有 provider 保留自己的间隔，`0` 只禁止自动调度。

- [ ] **Step 5: 提交调度器改动**

```powershell
git add -- companion/Private/RelayScheduler.ps1 tests/Unit/RelayScheduler.Tests.ps1
git commit -m "feat: restore provider relay intervals"
```

### Task 2: 移除设置 UI 和全局运行时链路

**Files:**
- Modify: `tests/Integration/SettingsComposition.Tests.ps1`
- Modify: `tests/Unit/SettingsController.Tests.ps1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`
- Modify: `tests/Integration/RelayRuntime.Tests.ps1`
- Modify: `companion/UI/Settings.xaml`
- Modify: `companion/Private/SettingsView.ps1`
- Modify: `companion/Private/SettingsController.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`
- Keep unchanged: `companion/Private/Settings.ps1`

- [ ] **Step 1: 写入失败的设置视图与控制器合同测试**

在 `SettingsComposition.Tests.ps1` 中删除 `OnSetRelayAutoQueryInterval`、快照参数和 interval 点击模拟，并加入：

```powershell
$View.Controls.Contains('AutoQueryIntervalTextBox') | Should -BeFalse
[IO.File]::ReadAllText($script:XamlPath) |
    Should -Not -Match '自动查询间隔|AutoQueryIntervalTextBox'
```

将快照调用统一为：

```powershell
& $View.SetSnapshot -Mode Orb -Theme Light -FullLayout Tabs `
    -Topmost $true -Startup $false
```

重写 `SettingsController.Tests.ps1` 的 fake view，使 `SetSnapshot` 和 `SetCallbacks` 只接受现存设置字段与回调：

```powershell
SetSnapshot = {
    param($Mode, $Theme, $FullLayout, $Topmost, $Startup)
    $viewState.Snapshot = [pscustomobject][ordered]@{
        Mode = $Mode
        Theme = $Theme
        FullLayout = $FullLayout
        Topmost = $Topmost
        Startup = $Startup
    }
}.GetNewClosure()
SetCallbacks = {
    param(
        $OnSetDisplayMode, $OnSetTheme, $OnSetFullLayout,
        $OnToggleTopmost, $OnToggleStartup,
        $OnRefresh, $OnManageRelays, $OnClosing
    )
    $viewState.Callbacks = [pscustomobject][ordered]@{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $viewState.Callbacks | Add-Member `
            -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
}.GetNewClosure()
```

构造控制器时不再传 `-SetRelayAutoQueryInterval`，并断言快照属性顺序为：

```powershell
($ViewState.Snapshot.PSObject.Properties.Name -join ',') |
    Should -BeExactly 'Mode,Theme,FullLayout,Topmost,Startup'
($ViewState.Callbacks.PSObject.Properties.Name -join ',') |
    Should -BeExactly 'OnSetDisplayMode,OnSetTheme,OnSetFullLayout,OnToggleTopmost,OnToggleStartup,OnRefresh,OnManageRelays,OnClosing'
```

- [ ] **Step 2: 写入失败的运行时组合测试**

在 `MonitorRuntime.Tests.ps1` 中：

- 让 `NewSettingsController` mock 不再声明或检查 `$SetRelayAutoQueryInterval`；
- 记录设置快照的属性名并断言不含 `RelayAutoQueryIntervalMinutes`；
- 让 `NewRelayScheduler` mock 只接收 `$Providers, $Now, $MaximumConcurrency`，调用真实调度器后记录 entry 间隔；
- 断言每次调度器创建的 entry 都使用现有 provider 的 `15`，而不是设置兼容字段中的 `7`；
- 断言运行后 `settings.json` 中兼容字段仍为 `7`，证明它没有被 UI 或运行时修改。

核心断言改为：

```powershell
@($settingsSnapshots) |
    Should -Be @('Mode,Theme,FullLayout,Topmost,Startup')
@($schedulerCreations).Count | Should -BeGreaterOrEqual 2
foreach ($creation in $schedulerCreations) {
    @($creation.EntryIntervals) | Should -Be @(15)
}
(Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).Relay.AutoQueryIntervalMinutes |
    Should -Be 7
```

在 `RelayRuntime.Tests.ps1` 中移除 `Invoke-TestRelayRuntime` 的 `AutoQueryIntervalMinutes` 参数、设置赋值和两个调用点的全局零值；provider 自身已是 `IntervalMinutes = 0` 的用例继续验证手动刷新。

- [ ] **Step 3: 运行四个聚焦测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { . .\build\Restore-TestDependencies.ps1; `$paths = @('.\tests\Integration\SettingsComposition.Tests.ps1','.\tests\Unit\SettingsController.Tests.ps1','.\tests\Integration\MonitorRuntime.Tests.ps1','.\tests\Integration\RelayRuntime.Tests.ps1'); `$r = Invoke-Pester -Path `$paths -Output Detailed -PassThru; if (`$r.Result -ne 'Passed') { exit 1 } }"
```

Expected: FAIL，因为设置控件、回调、运行时全局参数和覆盖行为仍存在。

- [ ] **Step 4: 删除设置视图与控制器中的全局间隔代码**

实施以下最小删除：

- 从 `Settings.xaml` 删除包含 `AutoQueryIntervalTextBox` 的整个 `StackPanel`；
- 从 `SettingsView.ps1` 删除该 control name、`LastRelayAutoQueryIntervalText`、LostFocus/Enter handlers、快照参数与赋值、`OnSetRelayAutoQueryInterval` 回调和 dispose 清理；
- 从 `SettingsController.ps1` 删除 `SetRelayAutoQueryInterval` 参数、解析 action、状态消息、快照参数和 callback 绑定；
- 保留模式、主题、布局、置顶、启动、立即刷新和管理中转站行为不变。

`New-SettingsController` 的参数合同应为：

```powershell
param(
    [Parameter(Mandatory)][object]$View,
    [Parameter(Mandatory)][scriptblock]$GetSnapshot,
    [Parameter(Mandatory)][scriptblock]$SetDisplayMode,
    [Parameter(Mandatory)][scriptblock]$SetTheme,
    [Parameter(Mandatory)][scriptblock]$SetFullLayout,
    [Parameter(Mandatory)][scriptblock]$ToggleTopmost,
    [Parameter(Mandatory)][scriptblock]$ToggleStartup,
    [Parameter(Mandatory)][scriptblock]$RequestRefresh,
    [Parameter()][AllowNull()][scriptblock]$ManageRelays = $null
)
```

- [ ] **Step 5: 删除运行时的全局覆盖参数与更新 action**

在 `CodexQuotaMonitor.psm1` 中，初始加载和 provider 变更时统一这样创建调度器：

```powershell
$runtime.RelayScheduler = & $newRelaySchedulerFunction `
    -Providers $runtime.RelayProviders -Now ([DateTimeOffset]::UtcNow) `
    -MaximumConcurrency 2
```

删除 `$setRelayAutoQueryIntervalAction`，从设置快照删除 `RelayAutoQueryIntervalMinutes`，并从 `NewSettingsController` 调用删除 `-SetRelayAutoQueryInterval`。不要修改 `Settings.ps1`，使旧 schema 3 字段继续被读取和写回但不生效。

- [ ] **Step 6: 运行聚焦测试并确认通过**

Run the Step 3 command.

Expected: PASS；设置 UI 无全局间隔，运行时所有 scheduler entry 使用 provider 自身值。

- [ ] **Step 7: 提交设置和运行时改动**

```powershell
git add -- companion/UI/Settings.xaml companion/Private/SettingsView.ps1 companion/Private/SettingsController.ps1 companion/CodexQuotaMonitor.psm1 tests/Integration/SettingsComposition.Tests.ps1 tests/Unit/SettingsController.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1 tests/Integration/RelayRuntime.Tests.ps1
git commit -m "feat: remove global relay interval setting"
```

### Task 3: 统一新建与导入默认值为 5 分钟

**Files:**
- Modify: `tests/Integration/RelayManagerComposition.Tests.ps1`
- Modify: `tests/Unit/CcSwitchUsageImport.Tests.ps1`
- Modify: `tests/Unit/RelayProviderStore.Tests.ps1`
- Modify: `tests/Unit/Documentation.Tests.ps1`
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `companion/Private/CcSwitchUsageImport.ps1`
- Modify: `companion/Presets/relay-usage.json`
- Modify: `docs/examples/generic-relay-provider.json`
- Modify: `README.md`

- [ ] **Step 1: 写入失败的默认值测试**

在 relay manager controller 测试中加入：

```powershell
It 'starts every new provider with a five-minute interval' {
    & $script:View.TestState.Callbacks.OnAdd

    $script:View.TestState.Draft.IntervalMinutes | Should -Be 5
}
```

在首次导入测试中给来源描述传不同值，并断言固定使用 5：

```powershell
$descriptor = New-TestCcSwitchDescriptor -IntervalMinutes 47 -Code @'
({
  request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { Authorization: "Bearer {{apiKey}}" } },
  extractor: function(response) { const data = response.data ?? response; return { isValid: true, remaining: data.balance, unit: data.currency ?? "USD" }; }
})
'@

$candidate = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
    -Endpoint 'https://api.wkkapi.com' -ImportMode Auto

$candidate.Draft.IntervalMinutes | Should -Be 5
```

保留现有更新导入测试中的以下断言：

```powershell
$sameOrigin.Draft.IntervalMinutes | Should -Be 60
```

把 preset 合同改为：

```powershell
@($registry.Presets.DefaultIntervalMinutes | Select-Object -Unique) |
    Should -BeExactly @(5)
```

在文档合同中加入：

```powershell
@($example.Providers.IntervalMinutes | Select-Object -Unique) |
    Should -BeExactly @(5)
$readme | Should -Match '每个中转站.*查询间隔'
$readme | Should -Match '默认.*5 分钟'
$readme | Should -Match '0.*手动'
```

- [ ] **Step 2: 运行默认值与文档测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { . .\build\Restore-TestDependencies.ps1; `$paths = @('.\tests\Integration\RelayManagerComposition.Tests.ps1','.\tests\Unit\CcSwitchUsageImport.Tests.ps1','.\tests\Unit\RelayProviderStore.Tests.ps1','.\tests\Unit\Documentation.Tests.ps1'); `$r = Invoke-Pester -Path `$paths -Output Detailed -PassThru; if (`$r.Result -ne 'Passed') { exit 1 } }"
```

Expected: FAIL，当前空白草稿、首次导入、预设和示例仍使用 10 或来源描述值。

- [ ] **Step 3: 实现统一 5 分钟默认值**

执行以下精确修改：

```powershell
# companion/Private/InteractionController.ps1, New-DefaultRelayProviderDraft
IntervalMinutes = 5
```

```powershell
# companion/Private/CcSwitchUsageImport.ps1, ConvertTo-CcSwitchRelayImportCandidate
$interval = if ($null -eq $ExistingProvider) {
    5
}
else {
    [int](Get-RelayProviderField $ExistingProvider 'IntervalMinutes')
}
```

将 `companion/Presets/relay-usage.json` 的三个 `DefaultIntervalMinutes` 和 `docs/examples/generic-relay-provider.json` 的两个 `IntervalMinutes` 全部改为 `5`。不要批量改动测试 fixture 中用于表达特定场景的显式间隔值。

- [ ] **Step 4: 更新 README 的入口和运行语义**

从设置列表和持久化段落删除全局间隔说明，并把中转站运行说明改为：

```text
“测试 provider”（旧界面称“测试脚本”）只执行一次手动验证并显示脱敏错误或归一化结果；“保存并启用”才会写入配置并加入自动调度。每个中转站在管理窗口中独立设置查询间隔，允许范围为 0–1440 分钟；新建和首次导入默认 5 分钟，设为 0 时该中转站只响应“立即刷新”和手动测试。修改一个中转站的间隔不会影响其他中转站。全局并发上限为 2。
```

保留随后关于 extractor、多套餐和单位隔离的现有说明。

- [ ] **Step 5: 运行默认值与文档测试并确认通过**

Run the Step 2 command.

Expected: PASS，新建、首次导入、预设和示例默认值均为 5，已有导入更新仍保留 60。

- [ ] **Step 6: 提交默认值和文档改动**

```powershell
git add -- companion/Private/InteractionController.ps1 companion/Private/CcSwitchUsageImport.ps1 companion/Presets/relay-usage.json docs/examples/generic-relay-provider.json README.md tests/Integration/RelayManagerComposition.Tests.ps1 tests/Unit/CcSwitchUsageImport.Tests.ps1 tests/Unit/RelayProviderStore.Tests.ps1 tests/Unit/Documentation.Tests.ps1
git commit -m "feat: default relay intervals to five minutes"
```

### Task 4: 完整回归验证

**Files:**
- Verify only: all files changed in Tasks 1-3

- [ ] **Step 1: 运行完整单元测试**

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Unit -CI
```

Expected: PASS，退出码 0，`outputs/test-results/Unit.xml` 生成。

- [ ] **Step 2: 运行完整集成测试**

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Integration -CI
```

Expected: PASS，退出码 0，`outputs/test-results/Integration.xml` 生成。

- [ ] **Step 3: 检查格式和残留全局运行时引用**

```powershell
git diff --check
rg -n "AutoQueryIntervalTextBox|RelayAutoQueryIntervalMinutes|SetRelayAutoQueryInterval|AutoQueryIntervalMinutes" companion/UI/Settings.xaml companion/Private/SettingsView.ps1 companion/Private/SettingsController.ps1 companion/CodexQuotaMonitor.psm1 companion/Private/RelayScheduler.ps1
```

Expected: `git diff --check` 无输出；`rg` 无匹配。`companion/Private/Settings.ps1` 中的兼容字段匹配不属于运行时残留。

- [ ] **Step 4: 检查最终差异只包含本任务文件**

```powershell
git status --short
git diff --stat HEAD~3..HEAD
```

Expected: 用户原有的 `companion/Private/WpfView.ps1` 与 `tests/Integration/WpfComposition.Tests.ps1` 仍保持未提交；本任务提交不包含这两个文件。

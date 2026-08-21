# 可控迷你额度、主界面刷新与双折叠自适应实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让完整窗口明确选择唯一的迷你模式额度项，补齐来源显示和手动刷新入口，并让两个额度分组可以同时折叠且窗口按自然内容高度收缩。

**Architecture:** 保持 `Compact.FocusMetric` 和 `DisplayModeController` 作为唯一选择状态。展示记录统一增加运行时 `SourceLabel`，控制器在自动模式或严格固定 Key 模式下只计算一次焦点记录，并把同一个记录和固定状态传给迷你条与额度球。完整窗口刷新按钮只触发与托盘共用的 `AutoResetEvent` 请求脚本块，WPF 高度继续交给 `SizeToContent` 和 Expander 自然测量。

**Tech Stack:** PowerShell 7.4、WPF/XAML、Pester 5.7.1、现有 Codex App Server/中转站调度运行时。

---

## 文件与职责

- Modify: `companion/Private/Presentation.ps1` — 官方展示记录补充 `SourceLabel = Codex 官方`。
- Modify: `companion/Private/RelayPresentation.ps1` — 中转站记录、复制辅助函数和严格固定选择保留 `SourceLabel`；具体 Key 不可用时返回空值而不回退。
- Modify: `companion/Private/DisplayModeController.ps1` — 将固定 Key 传给两个迷你视图，加入删除中转站后的焦点清理接口，并把刷新回调接入完整窗口。
- Modify: `companion/Private/WpfView.ps1` — 注册/释放标题栏刷新按钮、更新选择文案和卡片辅助功能名称。
- Modify: `companion/Private/CompactBarView.ps1` — 显示 `SourceLabel · Label`、完整悬浮提示和手动固定不可用占位态。
- Modify: `companion/Private/QuotaOrbView.ps1` — 与迷你条共用来源文本、悬浮提示和手动固定不可用占位态。
- Modify: `companion/Private/Theme.ps1` — 将刷新按钮纳入主题样式。
- Modify: `companion/UI/MainWindow.xaml` — 增加 `RefreshButton`，将 `MinHeight` 调为 136，并保持 Overview/Tabs 行为不变。
- Modify: `companion/CodexQuotaMonitor.psm1` — 用同一个 `requestRefreshAction` 连接标题栏、托盘和运行时事件，并在删除当前中转站时清理焦点。
- Modify: `tests/Unit/RelayPresentation.Tests.ps1` — 覆盖 SourceLabel、自动选择和严格固定选择。
- Modify: `tests/Unit/DisplayModeController.Tests.ps1` — 覆盖同一固定 Key/状态传递、单次持久化和删除焦点清理。
- Modify: `tests/Integration/WpfComposition.Tests.ps1` — 覆盖刷新按钮、选择文案、MinHeight 和双 Expander 测量。
- Modify: `tests/Integration/CompactBarComposition.Tests.ps1` — 覆盖来源文本、工具提示和不可用占位态。
- Modify: `tests/Integration/QuotaOrbComposition.Tests.ps1` — 覆盖来源文本、工具提示和不可用占位态。
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1` — 覆盖运行时把同一个刷新请求脚本块传给完整窗口和交互/托盘链路。

### Task 1: 展示记录与严格固定选择

- [x] **Step 1: 写失败测试**

在 `RelayPresentation.Tests.ps1` 的共享行工厂加入 `SourceLabel`，把精确属性顺序扩展为 `...,SourceId,SourceLabel,GroupLabel,...`，并增加以下断言：中转站行的 `SourceLabel` 是提供方名称、官方适配行的 `SourceLabel` 是 `Codex 官方`；具体固定 Key 找不到或该行不可用时，即使其它行可用也返回空值。

- [x] **Step 2: 运行相关测试确认红灯**

运行：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit -CI
```

预期：新增 SourceLabel 和严格固定选择断言失败，失败原因必须是实现尚未提供字段/错误回退。

- [x] **Step 3: 实现最小展示层改动**

在两个适配器和 `Copy-MonitorPresentationRow` 的同一属性位置写入 `SourceLabel`；`Get-CompactFocusRow` 先处理非空 `PinnedKey`，只返回精确匹配且可用的行，否则直接返回 `$null`，只有 `PinnedKey` 为空时才执行最低 `ProgressValue` 自动排序。

- [x] **Step 4: 运行测试确认绿灯**

运行 `Invoke-Pester .\tests\Unit\RelayPresentation.Tests.ps1 -Output Detailed`，确认新增和既有测试均通过。

### Task 2: 控制器与迷你视图共享严格状态

- [x] **Step 1: 写失败测试**

在 `DisplayModeController.Tests.ps1` 断言 `SetSnapshot` 后 CompactBar 与 Orb 收到同一 `PinnedKey`；固定一个官方百分比、一个中转站百分比和一个绝对余额时都保留对应 Key；固定 Key 缺失时两个视图的 Row 都为空但 PinnedKey 仍保留；调用删除中转站焦点清理接口后 `Settings.Compact.FocusMetric` 为 `Auto` 且只保存一次。

- [x] **Step 2: 运行测试确认红灯**

运行：

```powershell
Invoke-Pester .\tests\Unit\DisplayModeController.Tests.ps1 -Output Detailed
```

预期：CompactBar 当前没有收到 `PinnedKey`，且控制器没有删除焦点清理接口/调用。

- [x] **Step 3: 实现最小控制器改动**

在 `renderSnapshot` 中计算 `$pinnedKey` 后同时调用 `RenderFocus -Row $focus -PinnedKey $pinnedKey`；新增按 `relay:<ProviderId>:` 前缀匹配当前 Key 的 `ResetFocusForProvider`，命中时复用 `SetFocusKey Auto`；完整窗口 `SetCallbacks` 增加 `OnRefreshRequested`，并在 dispose 时传 `$null`。

- [x] **Step 4: 运行测试确认绿灯**

运行 `Invoke-Pester .\tests\Unit\DisplayModeController.Tests.ps1 -Output Detailed`，确认所有状态和持久化断言通过。

### Task 3: WPF 完整窗口刷新、来源文案与双折叠高度

- [x] **Step 1: 写失败测试**

在 `WpfComposition.Tests.ps1` 增加 `RefreshButton` 控件合同、内容 `↻`、工具提示 `立即刷新`、辅助功能名称 `立即刷新官方和中转站额度`、点击一次回调和 dispose 后不再回调；把 `MinHeight` 断言改为 136，并测量两个 Expander 同时折叠后高度小于展开状态、重新展开后恢复且 ScrollViewer `MaxHeight` 仍不超过 560。更新选择按钮断言为 `设为迷你模式显示项` / `取消迷你模式固定显示`。

- [x] **Step 2: 运行 WPF 测试确认红灯**

运行：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\WpfComposition.Tests.ps1, .\tests\Integration\CompactBarComposition.Tests.ps1, .\tests\Integration\QuotaOrbComposition.Tests.ps1 -Output Detailed"
```

预期：新增按钮、来源文案、不可用占位态或 MinHeight 断言失败。

- [x] **Step 3: 实现完整窗口与主题**

在 `MainWindow.xaml` 的标题栏 `LayoutButton` 后插入 `RefreshButton` 并顺延 Hide/Close 列；把 `MinHeight` 设为 `136`。在 `WpfView.ps1` 的控件列表、回调字典、点击委托和 dispose 解绑中加入刷新按钮，卡片选择状态使用 `●/○`，工具提示和 Automation 名称使用 spec 的两条中文文案。`Theme.ps1` 将 `RefreshButton` 加入按钮循环。

- [x] **Step 4: 实现迷你条与额度球显示**

两个视图都用 `SourceLabel · Label` 作为项目说明；当 `PinnedKey` 非空而 Row 为空时渲染 `所选额度暂不可用`、`—` 并隐藏进度；自动模式无候选时保留 `暂无可比较额度`。为 compact/orb 根容器设置只包含来源、项目名、值、新鲜度和重置时间的工具提示，依赖 WPF `TextTrimming=CharacterEllipsis` 截断可视文本而不泄露 URL/凭据。

- [x] **Step 5: 运行 WPF 测试确认绿灯**

运行上面的三个 WPF 集成测试命令，确认刷新回调生命周期、来源文本、占位态、折叠测量和既有主题/拖动测试全部通过。

### Task 4: 运行时接线与删除焦点清理

- [x] **Step 1: 写失败运行时测试**

在 `MonitorRuntime.Tests.ps1` 的桌面组合 override 捕获 `NewWindow` 和 `NewDisplay` 收到的 `OnRefreshRequested`，并捕获 `NewInteraction` 的 `RequestRefresh`；断言三者是同一 scriptblock 引用，调用按钮回调和交互刷新都只设置同一个事件通道。

- [x] **Step 2: 运行测试确认红灯**

运行：

```powershell
Invoke-Pester .\tests\Integration\MonitorRuntime.Tests.ps1 -Output Detailed
```

预期：现有运行时没有向 `NewWindow`/`NewDisplay` 传递刷新回调，新增参数断言失败。

- [x] **Step 3: 实现运行时接线**

在创建桌面视图前创建 `requestRefreshAction`；该 action 先调用当前窗口的 `SetFreshness $false '正在刷新…'`（若窗口已存在），再调用已有 `RefreshEvent.Set()`；将同一 scriptblock 传给 `NewWindow -OnRefreshRequested`、`NewDisplay -OnRefreshRequested` 和 `NewInteraction -RequestRefresh`。删除中转站成功后的 artifact 清理调用 `DisplayController.ResetFocusForProvider`。

- [x] **Step 4: 运行测试确认绿灯**

运行 `Invoke-Pester .\tests\Integration\MonitorRuntime.Tests.ps1 -Output Detailed`，确认刷新请求不读取/写出凭据，保留最近有效额度，且删除/运行时回归测试通过。

### Task 5: 全量验证与安装验收

- [x] **Step 1: 运行格式与差异检查**

```powershell
git diff --check
```

预期：无输出且退出码为 0。

- [x] **Step 2: 运行完整 Pester 套件**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
```

预期：Unit 402 基线加新增测试、Integration 195 基线加新增测试全部通过，零失败。

- [x] **Step 3: 运行视觉矩阵**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

检查 Light/Dark、100%/150%、官方/中转站百分比/绝对余额固定、固定项暂不可用、双折叠和刷新按钮输出无截断/重叠。

- [x] **Step 4: 覆盖安装并健康检查**

使用仓库既有安装脚本覆盖当前用户安装，然后执行：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

确认 `Healthy=True`、`Installed=True`、`Running=True`，并检查已安装 `MainWindow.xaml`、`WpfView.ps1`、`CompactBarView.ps1`、`QuotaOrbView.ps1` 包含刷新按钮、SourceLabel 和严格固定行为。

- [x] **Step 5: 复核工作区**

运行 `git status --short` 与 `git diff --stat`，确认只包含本 spec 相关实现/测试/计划，保留原有未跟踪 `.superpowers/`，不提交、不推送，等待用户决定分支收尾方式。

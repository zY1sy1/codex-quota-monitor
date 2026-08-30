# 自适应主题设置中心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有单列设置窗口改为只包含可用功能、随浅色/深色主题切换并可继续扩展的三页设置中心。

**Architecture:** 先完成已有的中转站独立查询间隔计划，使设置视图合同不再包含全局间隔。随后由 `Theme.ps1` 提供不透明的设置窗口 palette，由 `SettingsView.ps1` 管理本地页面导航、主题资源和控件状态，由 `SettingsController.ps1` 在每次配置变更后重新读取权威快照；不增加持久化字段或新的运行时服务。

**Tech Stack:** PowerShell 7.4+、WPF/XAML、Pester 5.7.1、现有 Codex Quota Monitor 主题与窗口基础设施。

---

## 前置计划

本计划只负责设置中心，不重复实现调度器、provider 默认值和设置兼容字段。开始 Task 1 前，必须完整执行：

`docs/superpowers/plans/2026-08-30-provider-specific-relay-query-interval.md`

执行完成后运行：

```powershell
rg -n "AutoQueryIntervalTextBox|SetRelayAutoQueryInterval|RelayAutoQueryIntervalMinutes" `
    companion/UI/Settings.xaml `
    companion/Private/SettingsView.ps1 `
    companion/Private/SettingsController.ps1 `
    companion/CodexQuotaMonitor.psm1
```

Expected: 无输出。兼容字段只允许继续存在于 `companion/Private/Settings.ps1` 和对应设置测试中。

再运行前置计划的聚焦回归：

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$paths = @( `
        '.\tests\Unit\RelayScheduler.Tests.ps1', `
        '.\tests\Integration\SettingsComposition.Tests.ps1', `
        '.\tests\Unit\SettingsController.Tests.ps1', `
        '.\tests\Integration\MonitorRuntime.Tests.ps1', `
        '.\tests\Integration\RelayRuntime.Tests.ps1' `
    ); `
    `$r = Invoke-Pester -Path `$paths -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: PASS，退出码 0。

## 文件结构

- `companion/Private/Theme.ps1`：设置窗口不透明 palette 与动态资源应用；
- `companion/UI/Settings.xaml`：设置中心外壳、三页内容、控件模板和固定状态栏；
- `companion/Private/SettingsView.ps1`：XAML 加载、本地页面导航、快照渲染、主题与事件生命周期；
- `companion/Private/SettingsController.ps1`：运行时 action 调用、权威快照恢复和状态反馈；
- `tests/Integration/ThemeComposition.Tests.ps1`：palette、资源和对比度合同；
- `tests/Integration/SettingsComposition.Tests.ps1`：WPF 结构、导航、主题、辅助功能和事件路由合同；
- `tests/Unit/SettingsController.Tests.ps1`：成功重渲染、失败恢复、命令状态和 dispose 合同；
- `tests/Visual/Capture-SettingsMatrix.ps1`：独立的设置中心确定性视觉矩阵；
- `tests/Unit/Documentation.Tests.ps1`、`tests/Visual/README.md`、`README.md`：用户文档与视觉验证入口。

### Task 1: 添加设置窗口专用主题 palette

**Files:**
- Modify: `tests/Integration/ThemeComposition.Tests.ps1`
- Modify: `companion/Private/Theme.ps1`

- [ ] **Step 1: 写入失败的 palette 与资源应用测试**

在 `tests/Integration/ThemeComposition.Tests.ps1` 的主题 `Describe` 中加入：

```powershell
It 'returns the exact opaque settings palette contract for <Theme>' -ForEach @(
    @{
        Theme = 'Light'
        Surface = '#FFF9FAFA'
        Sidebar = '#FFF1F5F5'
        SurfaceStrong = '#FFFFFFFF'
        TextPrimary = '#FF201F1D'
        TextSecondary = '#FF6F6B67'
        Accent = '#FF348186'
        AccentText = '#FFFFFFFF'
        Success = '#FF24757A'
        Selection = '#FFE2F0F0'
        Border = '#FF7A878C'
        Separator = '#FFD1D9DC'
        Hover = '#FFEAF3F3'
        Pressed = '#FFD9EAEA'
        Danger = '#FFB42323'
    }
    @{
        Theme = 'Dark'
        Surface = '#FF323A4C'
        Sidebar = '#FF272E3D'
        SurfaceStrong = '#FF3A4358'
        TextPrimary = '#FFF4F3F1'
        TextSecondary = '#FFAFB8CB'
        Accent = '#FF58C2C7'
        AccentText = '#FF1F2832'
        Success = '#FF79D9DD'
        Selection = '#FF354D58'
        Border = '#FF8792A6'
        Separator = '#FF566074'
        Hover = '#FF3A4658'
        Pressed = '#FF425264'
        Danger = '#FFFFA0A0'
    }
) {
    $palette = Get-SettingsThemePalette -Theme $Theme

    @($palette.Keys) | Should -Be @(
        'Surface', 'Sidebar', 'SurfaceStrong', 'TextPrimary', 'TextSecondary',
        'Accent', 'AccentText', 'Success', 'Selection', 'Border',
        'Separator', 'Hover', 'Pressed', 'Danger'
    )
    foreach ($key in @($palette.Keys)) {
        $palette[$key] | Should -BeExactly (Get-Variable -Name $key -ValueOnly)
        $palette[$key] | Should -Match '^#FF'
    }
}

It 'applies every settings palette entry as a window dynamic resource' -ForEach @(
    @{ Theme = 'Light'; Accent = '#FF348186'; Tag = 'Light' }
    @{ Theme = 'Dark'; Accent = '#FF58C2C7'; Tag = 'Dark' }
) {
    $window = [Windows.Window]::new()
    try {
        $palette = Set-SettingsWindowTheme -Window $window -Theme $Theme

        $window.Tag | Should -BeExactly $Tag
        $palette.Accent | Should -BeExactly $Accent
        foreach ($key in @($palette.Keys)) {
            $window.Resources["Settings${key}Brush"].ToString() |
                Should -BeExactly $palette[$key]
        }
    }
    finally {
        $window.Close()
    }
}
```

在 `BeforeAll` 中加入确定性的 WCAG 对比度辅助函数：

```powershell
function Get-TestRelativeLuminance {
    param([Parameter(Mandatory)][string]$Color)
    $hex = $Color.TrimStart('#')
    if ($hex.Length -eq 8) { $hex = $hex.Substring(2) }
    $channels = for ($index = 0; $index -lt 6; $index += 2) {
        $channel = [Convert]::ToInt32($hex.Substring($index, 2), 16) / 255
        if ($channel -le 0.04045) {
            $channel / 12.92
        }
        else {
            [Math]::Pow(($channel + 0.055) / 1.055, 2.4)
        }
    }
    0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}

function Get-TestContrastRatio {
    param([string]$Foreground, [string]$Background)
    $first = Get-TestRelativeLuminance $Foreground
    $second = Get-TestRelativeLuminance $Background
    ([Math]::Max($first, $second) + 0.05) /
        ([Math]::Min($first, $second) + 0.05)
}
```

在 palette 测试后加入：

```powershell
It 'keeps settings text contrast at or above 4.5 to 1 for <Theme>' -ForEach @(
    @{ Theme = 'Light' }
    @{ Theme = 'Dark' }
) {
    $palette = Get-SettingsThemePalette -Theme $Theme

    foreach ($background in @(
        $palette.Surface, $palette.Sidebar, $palette.SurfaceStrong
    )) {
        Get-TestContrastRatio $palette.TextPrimary $background |
            Should -BeGreaterOrEqual 4.5
        Get-TestContrastRatio $palette.TextSecondary $background |
            Should -BeGreaterOrEqual 4.5
    }
    Get-TestContrastRatio $palette.AccentText $palette.Accent |
        Should -BeGreaterOrEqual 4.5
    Get-TestContrastRatio $palette.Success $palette.SurfaceStrong |
        Should -BeGreaterOrEqual 4.5
    Get-TestContrastRatio $palette.Success $palette.Selection |
        Should -BeGreaterOrEqual 4.5
    foreach ($background in @($palette.Surface, $palette.SurfaceStrong)) {
        Get-TestContrastRatio $palette.Accent $background |
            Should -BeGreaterOrEqual 3
        Get-TestContrastRatio $palette.Border $background |
            Should -BeGreaterOrEqual 3
    }
    Get-TestContrastRatio $palette.Danger $palette.SurfaceStrong |
        Should -BeGreaterOrEqual 4.5
}
```

- [ ] **Step 2: 运行主题测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$r = Invoke-Pester -Path .\tests\Integration\ThemeComposition.Tests.ps1 `
        -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: FAIL，`Get-SettingsThemePalette` 和 `Set-SettingsWindowTheme` 尚不存在。

- [ ] **Step 3: 实现不透明设置 palette 与资源更新函数**

在 `companion/Private/Theme.ps1` 的 `Get-MonitorThemePalette` 后加入：

```powershell
function Get-SettingsThemePalette {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Light', 'Dark')]
        [string]$Theme
    )

    if ($Theme -eq 'Light') {
        return [ordered]@{
            Surface = '#FFF9FAFA'
            Sidebar = '#FFF1F5F5'
            SurfaceStrong = '#FFFFFFFF'
            TextPrimary = '#FF201F1D'
            TextSecondary = '#FF6F6B67'
            Accent = '#FF348186'
            AccentText = '#FFFFFFFF'
            Success = '#FF24757A'
            Selection = '#FFE2F0F0'
            Border = '#FF7A878C'
            Separator = '#FFD1D9DC'
            Hover = '#FFEAF3F3'
            Pressed = '#FFD9EAEA'
            Danger = '#FFB42323'
        }
    }

    return [ordered]@{
        Surface = '#FF323A4C'
        Sidebar = '#FF272E3D'
        SurfaceStrong = '#FF3A4358'
        TextPrimary = '#FFF4F3F1'
        TextSecondary = '#FFAFB8CB'
        Accent = '#FF58C2C7'
        AccentText = '#FF1F2832'
        Success = '#FF79D9DD'
        Selection = '#FF354D58'
        Border = '#FF8792A6'
        Separator = '#FF566074'
        Hover = '#FF3A4658'
        Pressed = '#FF425264'
        Danger = '#FFFFA0A0'
    }
}

function Set-SettingsWindowTheme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme
    )

    $palette = Get-SettingsThemePalette -Theme $Theme
    foreach ($entry in $palette.GetEnumerator()) {
        $Window.Resources["Settings$($entry.Key)Brush"] =
            ConvertTo-MonitorThemeBrush $entry.Value
    }
    $Window.Tag = $Theme
    return $palette
}
```

- [ ] **Step 4: 运行主题测试并确认通过**

Run the Step 2 command.

Expected: PASS，两个 palette 合同和所有动态资源均匹配。

- [ ] **Step 5: 提交主题基础设施**

```powershell
git add -- companion/Private/Theme.ps1 tests/Integration/ThemeComposition.Tests.ps1
git commit -m "feat: add settings center theme palette"
```

### Task 2: 构建设定中心外壳与本地页面导航

**Files:**
- Modify: `tests/Integration/SettingsComposition.Tests.ps1`
- Modify: `companion/UI/Settings.xaml`
- Modify: `companion/Private/SettingsView.ps1`

- [ ] **Step 1: 把设置组合测试改为新外壳合同**

在前置计划已经移除全局间隔测试后，使用以下用例替换原先的控件列表、固定文本、快照和路由用例；保留图标、关闭复用和 dispose 用例：

```powershell
It 'loads the resizable three-page settings center shell' {
    [Threading.Thread]::CurrentThread.GetApartmentState().ToString() |
        Should -BeExactly 'STA'
    $View.Window | Should -BeOfType ([Windows.Window])
    $View.Window.Title | Should -BeExactly '设置'
    $View.Window.Width | Should -Be 720
    $View.Window.Height | Should -Be 520
    $View.Window.MinWidth | Should -Be 640
    $View.Window.MinHeight | Should -Be 460
    $View.Window.SizeToContent | Should -Be ([Windows.SizeToContent]::Manual)
    foreach ($name in @(
        'RootGrid', 'SidebarBorder',
        'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
        'AppearancePage', 'BehaviorPage', 'RelayPage',
        'DisplayModeGroup', 'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
        'ThemeGroup', 'LightThemeRadio', 'DarkThemeRadio',
        'FullLayoutGroup', 'OverviewLayoutRadio', 'TabsLayoutRadio',
        'LayoutAvailabilityText', 'TopmostCheckBox', 'StartupCheckBox',
        'RefreshButton', 'ManageRelaysButton', 'StatusText'
    )) {
        $View.Controls[$name] | Should -Not -BeNullOrEmpty
    }
}

It 'shows only implemented navigation pages with exact Chinese text' {
    $View.Controls.AppearanceNavRadio.Content | Should -BeExactly '外观'
    $View.Controls.BehaviorNavRadio.Content | Should -BeExactly '行为'
    $View.Controls.RelayNavRadio.Content | Should -BeExactly '中转站'
    $View.Controls.FullModeRadio.Content | Should -BeExactly '完整窗口'
    $View.Controls.CompactBarModeRadio.Content | Should -BeExactly '迷你条'
    $View.Controls.OrbModeRadio.Content | Should -BeExactly '额度球'
    $View.Controls.LightThemeRadio.Content.Children[1].Text |
        Should -BeExactly '浅色透明'
    $View.Controls.DarkThemeRadio.Content.Children[1].Text |
        Should -BeExactly '深色透明'
    $View.Controls.OverviewLayoutRadio.Content | Should -BeExactly '总览折叠'
    $View.Controls.TabsLayoutRadio.Content | Should -BeExactly '标签切换'
    $View.Controls.RefreshButton.Content | Should -BeExactly '立即刷新额度'
    $View.Controls.ManageRelaysButton.Content | Should -BeExactly '打开中转站管理器'

    $raw = [IO.File]::ReadAllText($script:XamlPath)
    $raw | Should -Not -Match '诊断|关于|AutoQueryIntervalTextBox|自动查询间隔'
}

It 'switches pages locally without invoking runtime callbacks' {
    $View.State.CurrentPage | Should -BeExactly 'Appearance'
    $View.Controls.AppearanceNavRadio.IsChecked | Should -BeTrue
    $View.Controls.AppearancePage.Visibility | Should -Be ([Windows.Visibility]::Visible)

    & $View.SetPage 'Behavior'
    $View.Controls.AppearancePage.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    $View.Controls.BehaviorPage.Visibility | Should -Be ([Windows.Visibility]::Visible)
    $View.Controls.RelayPage.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    $View.Controls.BehaviorNavRadio.IsChecked | Should -BeTrue

    $View.Controls.RelayNavRadio.RaiseEvent(
        [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
    )
    $View.State.CurrentPage | Should -BeExactly 'Relay'
    $View.Controls.RelayPage.Visibility | Should -Be ([Windows.Visibility]::Visible)
    @($script:Calls) | Should -Be @()
}

It 'applies a dark compact snapshot without invoking callbacks' {
    & $View.SetSnapshot -Mode CompactBar -Theme Dark -FullLayout Tabs `
        -Topmost $true -Startup $false

    $View.Window.Tag | Should -BeExactly 'Dark'
    $View.Window.Resources['SettingsAccentBrush'].ToString() |
        Should -BeExactly '#FF58C2C7'
    $View.Controls.CompactBarModeRadio.IsChecked | Should -BeTrue
    $View.Controls.DarkThemeRadio.IsChecked | Should -BeTrue
    $View.Controls.TabsLayoutRadio.IsChecked | Should -BeTrue
    $View.Controls.OverviewLayoutRadio.IsEnabled | Should -BeFalse
    $View.Controls.TabsLayoutRadio.IsEnabled | Should -BeFalse
    $View.Controls.LayoutAvailabilityText.Text |
        Should -BeExactly '仅完整窗口模式可用'
    $View.Controls.TopmostCheckBox.IsChecked | Should -BeTrue
    $View.Controls.StartupCheckBox.IsChecked | Should -BeFalse
    $View.Controls.StatusText.Text | Should -BeExactly '更改即时保存'
    @($script:Calls) | Should -Be @()
}

It 'reenables full-window layout without losing the saved selection' {
    & $View.SetSnapshot -Mode CompactBar -Theme Light -FullLayout Tabs `
        -Topmost $false -Startup $false
    & $View.SetSnapshot -Mode Full -Theme Light -FullLayout Tabs `
        -Topmost $false -Startup $false

    $View.Controls.TabsLayoutRadio.IsChecked | Should -BeTrue
    $View.Controls.OverviewLayoutRadio.IsEnabled | Should -BeTrue
    $View.Controls.TabsLayoutRadio.IsEnabled | Should -BeTrue
}

It 'routes settings and commands exactly once while navigation stays local' {
    & $View.SetSnapshot -Mode Full -Theme Dark -FullLayout Overview `
        -Topmost $false -Startup $false

    foreach ($controlName in @(
        'CompactBarModeRadio', 'LightThemeRadio', 'TabsLayoutRadio',
        'TopmostCheckBox', 'StartupCheckBox', 'RefreshButton', 'ManageRelaysButton'
    )) {
        $View.Controls[$controlName].RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
    }
    @($script:Calls) | Should -Be @(
        'mode:CompactBar', 'theme:Light', 'layout:Tabs',
        'topmost', 'startup', 'refresh', 'relays'
    )
}

It 'renders idle success and error statuses in a fixed live region' {
    & $View.SetStatus '设置已同步' 'Success'
    $View.Controls.StatusText.Text | Should -BeExactly '设置已同步'
    $View.Controls.StatusText.Foreground.ToString() | Should -BeExactly '#FF24757A'

    & $View.SetStatus '无法应用主题：测试错误' 'Error'
    $View.Controls.StatusText.Text | Should -BeExactly '无法应用主题：测试错误'
    $View.Controls.StatusText.Foreground.ToString() | Should -BeExactly '#FFB42323'
    [Windows.Automation.AutomationProperties]::GetLiveSetting($View.Controls.StatusText) |
        Should -Be ([Windows.Automation.AutomationLiveSetting]::Polite)
}
```

在同一文件加入 XML 辅助功能合同：

```powershell
It 'gives every interactive settings control an automation name' {
    [xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw
    $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
    $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    foreach ($name in @(
        'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
        'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
        'LightThemeRadio', 'DarkThemeRadio',
        'OverviewLayoutRadio', 'TabsLayoutRadio',
        'TopmostCheckBox', 'StartupCheckBox',
        'RefreshButton', 'ManageRelaysButton'
    )) {
        $node = $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager)
        $node | Should -Not -BeNullOrEmpty
        $node.GetAttribute('AutomationProperties.Name') |
            Should -Not -BeNullOrEmpty
    }
}
```

加入原生键盘语义合同：

```powershell
It 'uses native focusable controls for navigation, segments, switches and commands' {
    foreach ($name in @(
        'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
        'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
        'LightThemeRadio', 'DarkThemeRadio',
        'OverviewLayoutRadio', 'TabsLayoutRadio'
    )) {
        $View.Controls[$name] | Should -BeOfType ([Windows.Controls.RadioButton])
        $View.Controls[$name].Focusable | Should -BeTrue
        $View.Controls[$name].IsTabStop | Should -BeTrue
    }
    foreach ($name in @('TopmostCheckBox', 'StartupCheckBox')) {
        $View.Controls[$name] | Should -BeOfType ([Windows.Controls.CheckBox])
        $View.Controls[$name].Focusable | Should -BeTrue
        $View.Controls[$name].IsTabStop | Should -BeTrue
        $View.Controls[$name].Width | Should -BeGreaterOrEqual 48
        $View.Controls[$name].Height | Should -BeGreaterOrEqual 36
    }
    foreach ($name in @('RefreshButton', 'ManageRelaysButton')) {
        $View.Controls[$name] | Should -BeOfType ([Windows.Controls.Button])
        $View.Controls[$name].Focusable | Should -BeTrue
        $View.Controls[$name].IsTabStop | Should -BeTrue
    }
    $View.Controls.StatusText.Focusable | Should -BeFalse
}

It 'shares one visible theme-driven keyboard focus visual' {
    $focusStyle = $View.Window.Resources['SettingsFocusVisual']
    $focusStyle | Should -BeOfType ([Windows.Style])
    $templateSetter = @($focusStyle.Setters | Where-Object {
        $_.Property -eq [Windows.Controls.Control]::TemplateProperty
    })
    $templateSetter.Count | Should -Be 1
    $focusBorder = $templateSetter[0].Value.LoadContent()
    $focusBorder | Should -BeOfType ([Windows.Controls.Border])
    $focusBorder.BorderThickness.Left | Should -Be 1
    $brushReference = $focusBorder.ReadLocalValue(
        [Windows.Controls.Border]::BorderBrushProperty
    )
    $brushReference.ResourceKey | Should -BeExactly 'SettingsAccentBrush'

    foreach ($name in @(
        'AppearanceNavRadio', 'FullModeRadio', 'LightThemeRadio',
        'TopmostCheckBox', 'RefreshButton', 'ManageRelaysButton'
    )) {
        $View.Controls[$name].FocusVisualStyle | Should -Be $focusStyle
    }
}
```

更新 `BeforeAll`，在加载 `SettingsView.ps1` 前点入 `Theme.ps1`；更新 `BeforeEach` 的 `SetCallbacks` 调用为前置计划移除 interval 后的签名。

- [ ] **Step 2: 运行设置组合测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$r = Invoke-Pester -Path .\tests\Integration\SettingsComposition.Tests.ps1 `
        -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: FAIL，因为三页外壳、主题资源、`SetPage`、禁用状态和状态类型尚不存在。

- [ ] **Step 3: 用三页设置中心替换 XAML 布局**

在 `companion/UI/Settings.xaml` 中实施以下完整结构合同：

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="设置"
        Width="720" Height="520"
        MinWidth="640" MinHeight="460"
        ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource SettingsSurfaceBrush}"
        Foreground="{DynamicResource SettingsTextPrimaryBrush}"
        FontFamily="Segoe UI"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        AutomationProperties.Name="Codex 额度监控设置">
    <Window.Resources>
        <SolidColorBrush x:Key="SettingsSurfaceBrush" Color="#FFF9FAFA" />
        <SolidColorBrush x:Key="SettingsSidebarBrush" Color="#FFF1F5F5" />
        <SolidColorBrush x:Key="SettingsSurfaceStrongBrush" Color="#FFFFFFFF" />
        <SolidColorBrush x:Key="SettingsTextPrimaryBrush" Color="#FF201F1D" />
        <SolidColorBrush x:Key="SettingsTextSecondaryBrush" Color="#FF6F6B67" />
        <SolidColorBrush x:Key="SettingsAccentBrush" Color="#FF348186" />
        <SolidColorBrush x:Key="SettingsAccentTextBrush" Color="#FFFFFFFF" />
        <SolidColorBrush x:Key="SettingsSuccessBrush" Color="#FF24757A" />
        <SolidColorBrush x:Key="SettingsSelectionBrush" Color="#FFE2F0F0" />
        <SolidColorBrush x:Key="SettingsBorderBrush" Color="#FF7A878C" />
        <SolidColorBrush x:Key="SettingsSeparatorBrush" Color="#FFD1D9DC" />
        <SolidColorBrush x:Key="SettingsHoverBrush" Color="#FFEAF3F3" />
        <SolidColorBrush x:Key="SettingsPressedBrush" Color="#FFD9EAEA" />
        <SolidColorBrush x:Key="SettingsDangerBrush" Color="#FFB42323" />

        <Style x:Key="SettingsFocusVisual">
            <Setter Property="Control.Template">
                <Setter.Value>
                    <ControlTemplate>
                        <Border Margin="2" CornerRadius="4"
                                BorderThickness="1"
                                BorderBrush="{DynamicResource SettingsAccentBrush}" />
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NavigationRadioStyle" TargetType="RadioButton">
            <Setter Property="MinHeight" Value="40" />
            <Setter Property="Margin" Value="0,2" />
            <Setter Property="Padding" Value="14,0,8,0" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextSecondaryBrush}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="FocusVisualStyle" Value="{StaticResource SettingsFocusVisual}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Grid Background="Transparent">
                            <Border x:Name="NavigationSurface"
                                    Background="{TemplateBinding Background}"
                                    CornerRadius="4" />
                            <Border x:Name="NavigationAccent"
                                    Width="3" HorizontalAlignment="Left"
                                    Background="{DynamicResource SettingsAccentBrush}"
                                    Visibility="Collapsed" />
                            <ContentPresenter Margin="{TemplateBinding Padding}"
                                              VerticalAlignment="Center" />
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="NavigationSurface" Property="Background"
                                        Value="{DynamicResource SettingsHoverBrush}" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="NavigationSurface" Property="Background"
                                        Value="{DynamicResource SettingsSelectionBrush}" />
                                <Setter TargetName="NavigationAccent" Property="Visibility" Value="Visible" />
                                <Setter Property="Foreground" Value="{DynamicResource SettingsSuccessBrush}" />
                                <Setter Property="FontWeight" Value="SemiBold" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SegmentRadioStyle" TargetType="RadioButton">
            <Setter Property="MinHeight" Value="36" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextPrimaryBrush}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderBrush" Value="{DynamicResource SettingsBorderBrush}" />
            <Setter Property="BorderThickness" Value="0,0,1,0" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{StaticResource SettingsFocusVisual}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="SegmentSurface"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="SegmentSurface" Property="Background"
                                        Value="{DynamicResource SettingsHoverBrush}" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="SegmentSurface" Property="Background"
                                        Value="{DynamicResource SettingsAccentBrush}" />
                                <Setter Property="Foreground" Value="{DynamicResource SettingsAccentTextBrush}" />
                                <Setter Property="FontWeight" Value="SemiBold" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="LastSegmentRadioStyle" TargetType="RadioButton"
               BasedOn="{StaticResource SegmentRadioStyle}">
            <Setter Property="BorderThickness" Value="0" />
        </Style>

        <Style x:Key="ThemeChoiceRadioStyle" TargetType="RadioButton">
            <Setter Property="MinHeight" Value="36" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextPrimaryBrush}" />
            <Setter Property="Background" Value="{DynamicResource SettingsSurfaceStrongBrush}" />
            <Setter Property="BorderBrush" Value="{DynamicResource SettingsBorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Margin" Value="0,0,8,0" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{StaticResource SettingsFocusVisual}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="ThemeChoiceSurface" CornerRadius="5"
                                Padding="{TemplateBinding Padding}"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThemeChoiceSurface" Property="Background"
                                        Value="{DynamicResource SettingsHoverBrush}" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ThemeChoiceSurface" Property="BorderBrush"
                                        Value="{DynamicResource SettingsAccentBrush}" />
                                <Setter Property="BorderThickness" Value="2" />
                                <Setter Property="FontWeight" Value="SemiBold" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SwitchCheckBoxStyle" TargetType="CheckBox">
            <Setter Property="Width" Value="48" />
            <Setter Property="Height" Value="36" />
            <Setter Property="FocusVisualStyle" Value="{StaticResource SettingsFocusVisual}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Width="48" Height="36" Background="Transparent">
                            <Border x:Name="SwitchTrack" Width="42" Height="22"
                                    HorizontalAlignment="Center" VerticalAlignment="Center"
                                    CornerRadius="11"
                                    Background="{DynamicResource SettingsBorderBrush}">
                                <Ellipse x:Name="SwitchThumb" Width="16" Height="16"
                                         Margin="3" HorizontalAlignment="Left"
                                         Fill="{DynamicResource SettingsSurfaceStrongBrush}"
                                         Stroke="{DynamicResource SettingsTextSecondaryBrush}"
                                         StrokeThickness="1" />
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="SwitchTrack" Property="Background"
                                        Value="{DynamicResource SettingsHoverBrush}" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="SwitchTrack" Property="Background"
                                        Value="{DynamicResource SettingsAccentBrush}" />
                                <Setter TargetName="SwitchThumb" Property="HorizontalAlignment" Value="Right" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CommandButtonStyle" TargetType="Button">
            <Setter Property="MinHeight" Value="36" />
            <Setter Property="Padding" Value="14,0" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsAccentTextBrush}" />
            <Setter Property="Background" Value="{DynamicResource SettingsAccentBrush}" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FocusVisualStyle" Value="{StaticResource SettingsFocusVisual}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="CommandSurface" CornerRadius="5"
                                Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CommandSurface" Property="Opacity" Value="0.9" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CommandSurface" Property="Background"
                                        Value="{DynamicResource SettingsPressedBrush}" />
                                <Setter Property="Foreground" Value="{DynamicResource SettingsTextPrimaryBrush}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PageTitleStyle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="21" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextPrimaryBrush}" />
        </Style>
        <Style x:Key="PageDescriptionStyle" TargetType="TextBlock">
            <Setter Property="Margin" Value="0,4,0,0" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextSecondaryBrush}" />
            <Setter Property="TextWrapping" Value="Wrap" />
        </Style>
        <Style x:Key="SettingTitleStyle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextPrimaryBrush}" />
        </Style>
        <Style x:Key="SettingDescriptionStyle" TargetType="TextBlock">
            <Setter Property="Margin" Value="0,3,0,0" />
            <Setter Property="FontSize" Value="11" />
            <Setter Property="Foreground" Value="{DynamicResource SettingsTextSecondaryBrush}" />
            <Setter Property="TextWrapping" Value="Wrap" />
        </Style>
    </Window.Resources>

    <Grid x:Name="RootGrid" Background="{DynamicResource SettingsSurfaceBrush}">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="156" />
            <ColumnDefinition Width="*" />
        </Grid.ColumnDefinitions>

        <Border x:Name="SidebarBorder" Grid.Column="0"
                Background="{DynamicResource SettingsSidebarBrush}"
                BorderBrush="{DynamicResource SettingsSeparatorBrush}"
                BorderThickness="0,0,1,0">
            <Grid Margin="12">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <TextBlock Text="额度监控" FontWeight="SemiBold"
                           Foreground="{DynamicResource SettingsTextPrimaryBrush}"
                           Margin="10,6,10,18" />
                <StackPanel Grid.Row="1">
                    <RadioButton x:Name="AppearanceNavRadio" Content="外观" Tag="Appearance"
                                 GroupName="SettingsNavigation" Style="{StaticResource NavigationRadioStyle}"
                                 AutomationProperties.Name="打开外观设置" />
                    <RadioButton x:Name="BehaviorNavRadio" Content="行为" Tag="Behavior"
                                 GroupName="SettingsNavigation" Style="{StaticResource NavigationRadioStyle}"
                                 AutomationProperties.Name="打开行为设置" />
                    <RadioButton x:Name="RelayNavRadio" Content="中转站" Tag="Relay"
                                 GroupName="SettingsNavigation" Style="{StaticResource NavigationRadioStyle}"
                                 AutomationProperties.Name="打开中转站设置" />
                </StackPanel>
                <TextBlock Grid.Row="2" Text="更改即时保存" FontSize="10"
                           Margin="10,8" Foreground="{DynamicResource SettingsTextSecondaryBrush}" />
            </Grid>
        </Border>

        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="*" />
                <RowDefinition Height="40" />
            </Grid.RowDefinitions>
            <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"
                          HorizontalScrollBarVisibility="Disabled">
                <Grid Margin="28,24,28,18">
                    <StackPanel x:Name="AppearancePage">
                        <TextBlock Text="外观" Style="{StaticResource PageTitleStyle}" />
                        <TextBlock Text="调整额度监控窗口的显示方式"
                                   Style="{StaticResource PageDescriptionStyle}" />

                        <StackPanel Margin="0,28,0,0">
                            <TextBlock Text="显示模式" Style="{StaticResource SettingTitleStyle}" />
                            <TextBlock Text="选择桌面额度窗口的形态"
                                       Style="{StaticResource SettingDescriptionStyle}" />
                            <Border x:Name="DisplayModeGroup" Height="38" Margin="0,10,0,0"
                                    CornerRadius="5" BorderThickness="1"
                                    BorderBrush="{DynamicResource SettingsBorderBrush}"
                                    Background="{DynamicResource SettingsSurfaceStrongBrush}">
                                <UniformGrid Columns="3">
                                    <RadioButton x:Name="FullModeRadio" Content="完整窗口"
                                                 GroupName="DisplayModeGroup" Tag="Full"
                                                 Style="{StaticResource SegmentRadioStyle}"
                                                 AutomationProperties.Name="显示模式：完整窗口" />
                                    <RadioButton x:Name="CompactBarModeRadio" Content="迷你条"
                                                 GroupName="DisplayModeGroup" Tag="CompactBar"
                                                 Style="{StaticResource SegmentRadioStyle}"
                                                 AutomationProperties.Name="显示模式：迷你条" />
                                    <RadioButton x:Name="OrbModeRadio" Content="额度球"
                                                 GroupName="DisplayModeGroup" Tag="Orb"
                                                 Style="{StaticResource LastSegmentRadioStyle}"
                                                 AutomationProperties.Name="显示模式：额度球" />
                                </UniformGrid>
                            </Border>

                            <Border Height="1" Margin="0,20"
                                    Background="{DynamicResource SettingsSeparatorBrush}" />
                            <TextBlock Text="主题" Style="{StaticResource SettingTitleStyle}" />
                            <TextBlock Text="设置中心会同步切换明暗主题"
                                       Style="{StaticResource SettingDescriptionStyle}" />
                            <UniformGrid x:Name="ThemeGroup" Columns="2" Margin="0,10,0,0">
                                <RadioButton x:Name="LightThemeRadio" GroupName="ThemeGroup" Tag="Light"
                                             Style="{StaticResource ThemeChoiceRadioStyle}"
                                             AutomationProperties.Name="主题：浅色透明">
                                    <StackPanel Orientation="Horizontal">
                                        <Border Width="16" Height="16" CornerRadius="3"
                                                Background="#FFF4EFEA" BorderBrush="#FFD1D9DC"
                                                BorderThickness="1" Margin="0,0,8,0" />
                                        <TextBlock Text="浅色透明" VerticalAlignment="Center" />
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="DarkThemeRadio" GroupName="ThemeGroup" Tag="Dark"
                                             Margin="0" Style="{StaticResource ThemeChoiceRadioStyle}"
                                             AutomationProperties.Name="主题：深色透明">
                                    <StackPanel Orientation="Horizontal">
                                        <Border Width="16" Height="16" CornerRadius="3"
                                                Background="#FF323A4C" BorderBrush="#FF707A90"
                                                BorderThickness="1" Margin="0,0,8,0" />
                                        <TextBlock Text="深色透明" VerticalAlignment="Center" />
                                    </StackPanel>
                                </RadioButton>
                            </UniformGrid>

                            <Border Height="1" Margin="0,20"
                                    Background="{DynamicResource SettingsSeparatorBrush}" />
                            <TextBlock Text="完整窗口布局" Style="{StaticResource SettingTitleStyle}" />
                            <TextBlock x:Name="LayoutAvailabilityText" Text="仅完整窗口模式可用"
                                       Style="{StaticResource SettingDescriptionStyle}" />
                            <Border x:Name="FullLayoutGroup" Height="38" Margin="0,10,0,0"
                                    CornerRadius="5" BorderThickness="1"
                                    BorderBrush="{DynamicResource SettingsBorderBrush}"
                                    Background="{DynamicResource SettingsSurfaceStrongBrush}">
                                <UniformGrid Columns="2">
                                    <RadioButton x:Name="OverviewLayoutRadio" Content="总览折叠"
                                                 GroupName="FullLayoutGroup" Tag="Overview"
                                                 Style="{StaticResource SegmentRadioStyle}"
                                                 AutomationProperties.Name="完整窗口布局：总览折叠" />
                                    <RadioButton x:Name="TabsLayoutRadio" Content="标签切换"
                                                 GroupName="FullLayoutGroup" Tag="Tabs"
                                                 Style="{StaticResource LastSegmentRadioStyle}"
                                                 AutomationProperties.Name="完整窗口布局：标签切换" />
                                </UniformGrid>
                            </Border>
                        </StackPanel>
                    </StackPanel>

                    <StackPanel x:Name="BehaviorPage" Visibility="Collapsed">
                        <TextBlock Text="行为" Style="{StaticResource PageTitleStyle}" />
                        <TextBlock Text="控制窗口与系统启动行为"
                                   Style="{StaticResource PageDescriptionStyle}" />
                        <Grid Margin="0,28,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="1" />
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="1" />
                                <RowDefinition Height="Auto" />
                            </Grid.RowDefinitions>
                            <Grid Margin="0,0,0,16">
                                <Grid.ColumnDefinitions><ColumnDefinition /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="始终置顶" Style="{StaticResource SettingTitleStyle}" />
                                    <TextBlock Text="让当前额度窗口保持在其他窗口上方"
                                               Style="{StaticResource SettingDescriptionStyle}" />
                                </StackPanel>
                                <CheckBox x:Name="TopmostCheckBox" Grid.Column="1"
                                          VerticalAlignment="Center"
                                          Style="{StaticResource SwitchCheckBoxStyle}"
                                          AutomationProperties.Name="始终置顶" />
                            </Grid>
                            <Border Grid.Row="1" Background="{DynamicResource SettingsSeparatorBrush}" />
                            <Grid Grid.Row="2" Margin="0,16">
                                <Grid.ColumnDefinitions><ColumnDefinition /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="开机启动" Style="{StaticResource SettingTitleStyle}" />
                                    <TextBlock Text="登录 Windows 后自动启动额度监控"
                                               Style="{StaticResource SettingDescriptionStyle}" />
                                </StackPanel>
                                <CheckBox x:Name="StartupCheckBox" Grid.Column="1"
                                          VerticalAlignment="Center"
                                          Style="{StaticResource SwitchCheckBoxStyle}"
                                          AutomationProperties.Name="开机启动" />
                            </Grid>
                            <Border Grid.Row="3" Background="{DynamicResource SettingsSeparatorBrush}" />
                            <Grid Grid.Row="4" Margin="0,18,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="刷新额度" Style="{StaticResource SettingTitleStyle}" />
                                    <TextBlock Text="请求官方额度和已启用中转站立即刷新"
                                               Style="{StaticResource SettingDescriptionStyle}" />
                                </StackPanel>
                                <Button x:Name="RefreshButton" Grid.Column="1" Content="立即刷新额度"
                                        VerticalAlignment="Center"
                                        Style="{StaticResource CommandButtonStyle}"
                                        AutomationProperties.Name="立即刷新官方和中转站额度" />
                            </Grid>
                        </Grid>
                    </StackPanel>

                    <StackPanel x:Name="RelayPage" Visibility="Collapsed">
                        <TextBlock Text="中转站" Style="{StaticResource PageTitleStyle}" />
                        <TextBlock Text="管理独立于 Codex 官方额度的第三方额度来源"
                                   Style="{StaticResource PageDescriptionStyle}" />
                        <Grid Margin="0,28,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="中转站管理器" Style="{StaticResource SettingTitleStyle}" />
                                <TextBlock Text="添加、测试和配置中转站；每个中转站可设置自己的查询间隔"
                                           MaxWidth="360" Style="{StaticResource SettingDescriptionStyle}" />
                            </StackPanel>
                            <Button x:Name="ManageRelaysButton" Grid.Column="1"
                                    Content="打开中转站管理器"
                                    VerticalAlignment="Center"
                                    Style="{StaticResource CommandButtonStyle}"
                                    AutomationProperties.Name="打开中转站管理器" />
                        </Grid>
                    </StackPanel>
                </Grid>
            </ScrollViewer>

            <Border Grid.Row="1" Padding="28,0"
                    Background="{DynamicResource SettingsSurfaceStrongBrush}"
                    BorderBrush="{DynamicResource SettingsSeparatorBrush}"
                    BorderThickness="0,1,0,0">
                <TextBlock x:Name="StatusText" VerticalAlignment="Center"
                           Foreground="{DynamicResource SettingsTextSecondaryBrush}"
                           Text="更改即时保存" TextTrimming="CharacterEllipsis"
                           AutomationProperties.Name="设置状态"
                           AutomationProperties.LiveSetting="Polite" />
            </Border>
        </Grid>
    </Grid>
</Window>
```

- [ ] **Step 4: 更新视图以管理本地页面、主题与状态类型**

在 `companion/Private/SettingsView.ps1` 顶部同时保证图标和主题函数可用：

```powershell
if (-not (Get-Command Get-MonitorAppIconPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'WindowIcon.ps1')
}
if (-not (Get-Command Set-SettingsWindowTheme -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}
```

把 `$controlNames` 精确改为 Task 2 Step 1 的控件列表。把视图状态改为：

```powershell
$state = [pscustomobject][ordered]@{
    Window = $window
    Controls = $controls
    Callbacks = $null
    Disposed = $false
    CurrentPage = 'Appearance'
    Delegates = [ordered]@{}
}
```

在绑定设置回调前定义并绑定本地页面切换：

```powershell
$setPage = {
    param([ValidateSet('Appearance', 'Behavior', 'Relay')][string]$Page)
    if ($state.Disposed) { return }
    $state.CurrentPage = $Page
    foreach ($name in @('Appearance', 'Behavior', 'Relay')) {
        $state.Controls["${name}Page"].Visibility = if ($name -eq $Page) {
            [Windows.Visibility]::Visible
        }
        else {
            [Windows.Visibility]::Collapsed
        }
        $state.Controls["${name}NavRadio"].IsChecked = ($name -eq $Page)
    }
}.GetNewClosure()

foreach ($definition in @(
    @{ Control = 'AppearanceNavRadio'; Page = 'Appearance' }
    @{ Control = 'BehaviorNavRadio'; Page = 'Behavior' }
    @{ Control = 'RelayNavRadio'; Page = 'Relay' }
)) {
    $page = $definition.Page
    $handler = [Windows.RoutedEventHandler]{
        param($sender, $args)
        & $setPage $page
    }.GetNewClosure()
    $state.Delegates[$definition.Control] = $handler
    $controls[$definition.Control].Add_Click($handler)
}
```

保留七个现有设置和命令控件的 Click 路由，不加入导航回调。用以下 `SetSnapshot` 替换前置计划后的版本：

```powershell
$setSnapshot = {
    param(
        [string]$Mode,
        [string]$Theme,
        [string]$FullLayout,
        [bool]$Topmost,
        [bool]$Startup
    )
    if ($state.Disposed) { return }

    $modeControl = switch ($Mode) {
        'CompactBar' { $state.Controls.CompactBarModeRadio }
        'Orb' { $state.Controls.OrbModeRadio }
        default { $state.Controls.FullModeRadio }
    }
    $themeControl = if ($Theme -eq 'Light') {
        $state.Controls.LightThemeRadio
    }
    else {
        $state.Controls.DarkThemeRadio
    }
    $layoutControl = if ($FullLayout -eq 'Tabs') {
        $state.Controls.TabsLayoutRadio
    }
    else {
        $state.Controls.OverviewLayoutRadio
    }

    foreach ($control in @(
        $state.Controls.FullModeRadio, $state.Controls.CompactBarModeRadio,
        $state.Controls.OrbModeRadio, $state.Controls.LightThemeRadio,
        $state.Controls.DarkThemeRadio, $state.Controls.OverviewLayoutRadio,
        $state.Controls.TabsLayoutRadio
    )) {
        $control.IsChecked = $false
    }
    $modeControl.IsChecked = $true
    $themeControl.IsChecked = $true
    $layoutControl.IsChecked = $true
    $state.Controls.TopmostCheckBox.IsChecked = $Topmost
    $state.Controls.StartupCheckBox.IsChecked = $Startup

    $layoutEnabled = ($Mode -eq 'Full')
    $state.Controls.OverviewLayoutRadio.IsEnabled = $layoutEnabled
    $state.Controls.TabsLayoutRadio.IsEnabled = $layoutEnabled
    $state.Controls.LayoutAvailabilityText.Text = '仅完整窗口模式可用'
    $null = Set-SettingsWindowTheme -Window $state.Window -Theme $Theme
    $state.Controls.StatusText.Text = '更改即时保存'
    $state.Controls.StatusText.Foreground =
        $state.Window.Resources['SettingsTextSecondaryBrush']
}.GetNewClosure()
```

用以下状态方法替换单参数版本：

```powershell
$setStatus = {
    param(
        [string]$Message,
        [ValidateSet('Idle', 'Success', 'Error')]
        [string]$Kind = 'Idle'
    )
    if ($state.Disposed) { return }
    $state.Controls.StatusText.Text = if ([string]::IsNullOrWhiteSpace($Message)) {
        '更改即时保存'
    }
    else {
        $Message
    }
    $brushKey = switch ($Kind) {
        'Success' { 'SettingsSuccessBrush' }
        'Error' { 'SettingsDangerBrush' }
        default { 'SettingsTextSecondaryBrush' }
    }
    $state.Controls.StatusText.Foreground = $state.Window.Resources[$brushKey]
}.GetNewClosure()
```

让 `ShowDialog` 每次重置到外观页：

```powershell
$showDialog = {
    if ($state.Disposed) { return }
    & $setPage 'Appearance'
    return $state.Window.ShowDialog()
}.GetNewClosure()
```

用以下 dispose 循环统一移除导航和运行时 Click handlers：

```powershell
$dispose = {
    if ($state.Disposed) { return }
    $state.Disposed = $true
    try { $window.remove_Closing($state.Delegates.Closing) } catch { }
    foreach ($name in @($state.Delegates.Keys)) {
        if ($name -eq 'Closing') { continue }
        if (-not $state.Controls.Contains($name)) { continue }
        try { $state.Controls[$name].remove_Click($state.Delegates[$name]) } catch { }
    }
    $state.Delegates.Clear()
    $state.Callbacks = $null
    try { $window.Close() } catch { }
}.GetNewClosure()
```

返回对象加入：

```powershell
SetPage = $setPage
```

在返回视图对象前执行一次：

```powershell
& $setPage 'Appearance'
```

- [ ] **Step 5: 运行设置组合与主题测试并确认通过**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$paths = @( `
        '.\tests\Integration\SettingsComposition.Tests.ps1', `
        '.\tests\Integration\ThemeComposition.Tests.ps1' `
    ); `
    `$r = Invoke-Pester -Path `$paths -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: PASS，三页导航、明暗主题、禁用状态和状态栏合同全部通过。

- [ ] **Step 6: 提交设置视图与 XAML**

```powershell
git add -- companion/UI/Settings.xaml companion/Private/SettingsView.ps1 `
    tests/Integration/SettingsComposition.Tests.ps1
git commit -m "feat: build adaptive settings center shell"
```

### Task 3: 让控制器在每次配置变更后恢复权威状态

**Files:**
- Modify: `tests/Unit/SettingsController.Tests.ps1`
- Modify: `companion/Private/SettingsController.ps1`

- [ ] **Step 1: 写入成功重渲染、失败恢复和状态类型测试**

在前置计划移除 interval 后的 fake view 中，让 `SetSnapshot` 递增 `$viewState.RenderCalls`，让 `SetStatus` 保存消息和类型：

```powershell
SetSnapshot = {
    param($Mode, $Theme, $FullLayout, $Topmost, $Startup)
    $viewState.RenderCalls++
    $viewState.Snapshot = [pscustomobject][ordered]@{
        Mode = $Mode
        Theme = $Theme
        FullLayout = $FullLayout
        Topmost = $Topmost
        Startup = $Startup
    }
    $viewState.Status = '更改即时保存'
    $viewState.StatusKind = 'Idle'
}.GetNewClosure()
SetStatus = {
    param($Message, $Kind)
    $viewState.Status = $Message
    $viewState.StatusKind = $Kind
}.GetNewClosure()
```

在 `BeforeEach` 初始化 `RenderCalls = 0`、`StatusKind = 'Idle'`，并用以下构造替换 controller fake actions，确保每个动作都更新权威快照：

```powershell
$script:Controller = New-SettingsController `
    -View $script:View `
    -GetSnapshot { $script:Snapshot } `
    -SetDisplayMode { param($value) $script:Snapshot.Mode = $value } `
    -SetTheme { param($value) $script:Snapshot.Theme = $value } `
    -SetFullLayout { param($value) $script:Snapshot.FullLayout = $value } `
    -ToggleTopmost {
        $script:Snapshot.Topmost = -not $script:Snapshot.Topmost
    } `
    -ToggleStartup {
        $script:Snapshot.Startup = -not $script:Snapshot.Startup
    } `
    -RequestRefresh { $script:RefreshCalls++ }
```

加入：

```powershell
It 'rerenders the authoritative snapshot after every successful setting change' {
    & $ViewState.Callbacks.OnSetDisplayMode 'CompactBar'
    & $ViewState.Callbacks.OnSetTheme 'Light'
    & $ViewState.Callbacks.OnSetFullLayout 'Tabs'
    & $ViewState.Callbacks.OnToggleTopmost
    & $ViewState.Callbacks.OnToggleStartup

    $ViewState.RenderCalls | Should -Be 5
    $ViewState.Snapshot.Mode | Should -BeExactly 'CompactBar'
    $ViewState.Snapshot.Theme | Should -BeExactly 'Light'
    $ViewState.Snapshot.FullLayout | Should -BeExactly 'Tabs'
    $ViewState.Snapshot.Topmost | Should -BeFalse
    $ViewState.Snapshot.Startup | Should -BeFalse
    $ViewState.Status | Should -BeExactly '设置已同步'
    $ViewState.StatusKind | Should -BeExactly 'Success'
}

It 'restores the snapshot and reports an error when a setting action fails' {
    & $script:Controller.Dispose
    $script:Controller = New-SettingsController `
        -View $script:View `
        -GetSnapshot { $script:Snapshot } `
        -SetDisplayMode { param($value) } `
        -SetTheme { param($value) throw 'theme failed' } `
        -SetFullLayout { param($value) } `
        -ToggleTopmost { } `
        -ToggleStartup { } `
        -RequestRefresh { }

    & $ViewState.Callbacks.OnSetTheme 'Light'

    $ViewState.RenderCalls | Should -Be 1
    $ViewState.Snapshot.Theme | Should -BeExactly 'Dark'
    $ViewState.Status | Should -BeExactly '无法应用主题：theme failed'
    $ViewState.StatusKind | Should -BeExactly 'Error'
}

It 'reports refresh as requested without claiming completion' {
    & $ViewState.Callbacks.OnRefresh

    $ViewState.Status | Should -BeExactly '已请求刷新。'
    $ViewState.StatusKind | Should -BeExactly 'Success'
}
```

将初始 `Show` 用例断言改为 `RenderCalls = 1` 且状态为 Idle。保留 dispose 幂等和回调清理测试。

- [ ] **Step 2: 运行控制器测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$r = Invoke-Pester -Path .\tests\Unit\SettingsController.Tests.ps1 `
        -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: FAIL，成功 action 尚未重渲染，`SetStatus` 也尚未传类型。

- [ ] **Step 3: 统一成功与失败 action 的完成路径**

在 `companion/Private/SettingsController.ps1` 的 `$render` 后定义：

```powershell
$completeSetting = {
    if ($state.Disposed) { return }
    & $render
    & $View.SetStatus '设置已同步' 'Success'
}.GetNewClosure()

$failWith = {
    param([string]$Prefix, [Exception]$ErrorRecord)
    if ($state.Disposed) { return }
    & $render
    & $View.SetStatus ("$Prefix" + [string]$ErrorRecord.Message) 'Error'
}.GetNewClosure()
```

把五个配置 action 精确改为以下模式：

```powershell
$setModeAction = {
    param([string]$Mode)
    if ($state.Disposed) { return }
    try {
        & $SetDisplayMode $Mode
        & $completeSetting
    }
    catch {
        & $failWith '无法应用显示模式：' $_.Exception
    }
}.GetNewClosure()

$setThemeAction = {
    param([string]$Theme)
    if ($state.Disposed) { return }
    try {
        & $SetTheme $Theme
        & $completeSetting
    }
    catch {
        & $failWith '无法应用主题：' $_.Exception
    }
}.GetNewClosure()

$setLayoutAction = {
    param([string]$Layout)
    if ($state.Disposed) { return }
    try {
        & $SetFullLayout $Layout
        & $completeSetting
    }
    catch {
        & $failWith '无法应用布局：' $_.Exception
    }
}.GetNewClosure()

$topmostAction = {
    if ($state.Disposed) { return }
    try {
        & $ToggleTopmost
        & $completeSetting
    }
    catch {
        & $failWith '无法切换置顶：' $_.Exception
    }
}.GetNewClosure()

$startupAction = {
    if ($state.Disposed) { return }
    try {
        & $ToggleStartup
        & $completeSetting
    }
    catch {
        & $failWith '无法切换开机启动：' $_.Exception
    }
}.GetNewClosure()
```

刷新成功改为：

```powershell
& $View.SetStatus '已请求刷新。' 'Success'
```

中转站管理器异常继续调用新的 `$failWith`；它会恢复权威快照并显示 Error 类型。控制器参数、快照字段和 callback 签名保持前置计划完成后的版本。

- [ ] **Step 4: 运行控制器与设置组合测试并确认通过**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$paths = @( `
        '.\tests\Unit\SettingsController.Tests.ps1', `
        '.\tests\Integration\SettingsComposition.Tests.ps1' `
    ); `
    `$r = Invoke-Pester -Path `$paths -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: PASS，所有配置动作重渲染，错误恢复，状态类型正确。

- [ ] **Step 5: 提交控制器行为**

```powershell
git add -- companion/Private/SettingsController.ps1 tests/Unit/SettingsController.Tests.ps1
git commit -m "feat: restore authoritative settings state"
```

### Task 4: 更新文档并添加独立设置视觉矩阵

**Files:**
- Modify: `tests/Unit/Documentation.Tests.ps1`
- Modify: `README.md`
- Create: `tests/Visual/Capture-SettingsMatrix.ps1`
- Modify: `tests/Visual/README.md`

- [ ] **Step 1: 写入设置中心文档合同**

在 `tests/Unit/Documentation.Tests.ps1` 加入：

```powershell
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
```

- [ ] **Step 2: 运行文档测试并确认失败**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "& { `
    . .\build\Restore-TestDependencies.ps1; `
    `$r = Invoke-Pester -Path .\tests\Unit\Documentation.Tests.ps1 `
        -Output Detailed -PassThru; `
    if (`$r.Result -ne 'Passed') { exit 1 } `
}"
```

Expected: FAIL，README 尚未描述三页设置中心和设置窗口自身换肤。

- [ ] **Step 3: 更新 README 设置章节**

把 README 的 `## 设置` 入口段落替换为：

```markdown
## 设置

托盘菜单中的“设置”打开三页设置中心：

- `外观`：显示模式、主题和完整窗口布局；
- `行为`：始终置顶、开机启动和立即刷新；
- `中转站`：打开中转站管理器，添加、测试和配置第三方额度来源。

设置会即时生效，不需要另行保存。切换浅色或深色主题时，设置中心自身和当前额度窗口会同步换肤；“完整窗口布局”仅在显示模式为完整窗口时可操作，切换到迷你条或额度球不会丢失已保存的布局。每个中转站在管理器内独立设置查询间隔，设置中心不再提供全局中转站查询间隔。
```

保留后续显示模式、主题和中转站安全边界说明，不重复列出已经存在的配置细节。

- [ ] **Step 4: 创建 18 张确定性设置窗口视觉捕获脚本**

创建 `tests/Visual/Capture-SettingsMatrix.ps1`：

```powershell
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\outputs\visual\settings')
)

if (-not $IsWindows) {
    throw 'The settings visual matrix requires Windows.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne
    [Threading.ApartmentState]::STA) {
    throw 'The settings visual matrix requires an STA thread.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$companionRoot = Join-Path $PSScriptRoot '..\..\companion'
. (Join-Path $companionRoot 'Private\Theme.ps1')
. (Join-Path $companionRoot 'Private\SettingsView.ps1')
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Save-SettingsMatrixVisual {
    param(
        [Parameter(Mandatory)][Windows.Window]$Window,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Scale,
        [AllowNull()][object]$FocusControl = $null
    )

    $Window.WindowState = [Windows.WindowState]::Normal
    $Window.ShowInTaskbar = $false
    $Window.Show()
    $Window.UpdateLayout()
    if ($null -ne $FocusControl) {
        $null = $FocusControl.Focus()
    }
    $content = $Window.Content
    $logicalWidth = [Math]::Max(1, $content.ActualWidth)
    $logicalHeight = [Math]::Max(1, $content.ActualHeight)
    $content.Measure([Windows.Size]::new($logicalWidth, $logicalHeight))
    $content.Arrange([Windows.Rect]::new(0, 0, $logicalWidth, $logicalHeight))
    $content.UpdateLayout()

    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int][Math]::Ceiling($logicalWidth * $Scale),
        [int][Math]::Ceiling($logicalHeight * $Scale),
        96 * $Scale, 96 * $Scale,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.FileStream]::new(
        $Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read
    )
    try { $encoder.Save($stream) }
    finally {
        $stream.Dispose()
        $Window.Hide()
    }
}

$captured = [Collections.Generic.List[string]]::new()
foreach ($theme in @('Light', 'Dark')) {
    $view = New-SettingsView
    try {
        foreach ($scale in @(1.0, 1.5)) {
            $dpi = if ($scale -eq 1.0) { '100' } else { '150' }
            foreach ($case in @(
                @{ Page = 'Appearance'; Mode = 'Full'; Name = 'appearance-full' }
                @{ Page = 'Appearance'; Mode = 'CompactBar'; Name = 'appearance-disabled' }
                @{ Page = 'Behavior'; Mode = 'Full'; Name = 'behavior' }
                @{ Page = 'Relay'; Mode = 'Full'; Name = 'relay' }
            )) {
                & $view.SetSnapshot -Mode $case.Mode -Theme $theme -FullLayout Tabs `
                    -Topmost $true -Startup $false
                & $view.SetPage $case.Page
                $path = Join-Path $OutputDirectory (
                    '{0}-{1}-{2}.png' -f $theme.ToLowerInvariant(), $dpi, $case.Name
                )
                Save-SettingsMatrixVisual -Window $view.Window -Path $path -Scale $scale
                $captured.Add($path)
            }
        }

        & $view.SetSnapshot -Mode Full -Theme $theme -FullLayout Overview `
            -Topmost $false -Startup $true
        & $view.SetPage 'Behavior'
        & $view.SetStatus '无法应用主题：视觉测试错误' 'Error'
        $errorPath = Join-Path $OutputDirectory (
            '{0}-100-behavior-error.png' -f $theme.ToLowerInvariant()
        )
        Save-SettingsMatrixVisual -Window $view.Window -Path $errorPath -Scale 1.0 `
            -FocusControl $view.Controls.RefreshButton
        $captured.Add($errorPath)
    }
    finally {
        & $view.Dispose
    }
}

if ($captured.Count -ne 18) {
    throw "Expected 18 settings captures, created $($captured.Count)."
}
Write-Output (
    'Captured {0} deterministic settings images under {1}' -f
        $captured.Count, $OutputDirectory
)
```

- [ ] **Step 5: 更新视觉 README 并运行矩阵**

在 `tests/Visual/README.md` 增加：

````markdown
## Settings center matrix

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-SettingsMatrix.ps1
```

The script writes 18 PNGs under `outputs/visual/settings`, covering all three pages, light and dark themes, 100% and 150% scale, the disabled full-layout state, and a focused error status. Review navigation selection, text clipping, keyboard-focus affordance, segment and switch alignment, fixed status height, and theme contrast.
````

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta `
    -File .\tests\Visual\Capture-SettingsMatrix.ps1
```

Expected: `Captured 18 deterministic settings images`，退出码 0。

- [ ] **Step 6: 检查全部设置截图**

逐张打开 `outputs/visual/settings/*.png`。确认：

- 三页标题、说明、控件和状态栏没有裁切或重叠；
- 100% 与 150% 的导航宽度、分段选择、开关和按钮不跳动；
- 浅色和深色状态均有清晰的选中、禁用和错误层级；
- 非完整模式保留 Tabs 选择但禁用两个布局选项；
- 错误状态不改变窗口内容尺寸。

- [ ] **Step 7: 运行文档测试并确认通过**

Run the Step 2 command.

Expected: PASS。

- [ ] **Step 8: 提交文档和视觉矩阵**

```powershell
git add -- README.md tests/Unit/Documentation.Tests.ps1 `
    tests/Visual/Capture-SettingsMatrix.ps1 tests/Visual/README.md
git commit -m "test: cover adaptive settings center visuals"
```

### Task 5: 完整回归与交付检查

**Files:**
- Verify only: all files changed in Tasks 1-4

- [ ] **Step 1: 运行完整单元测试**

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Unit -CI
```

Expected: PASS，退出码 0，生成 `outputs/test-results/Unit.xml`。

- [ ] **Step 2: 运行完整集成测试**

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Integration -CI
```

Expected: PASS，退出码 0，生成 `outputs/test-results/Integration.xml`。

- [ ] **Step 3: 运行原有额度窗口视觉矩阵**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta `
    -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

Expected: `Captured 44 deterministic quota-monitor images`，证明共享主题改动没有破坏额度窗口。

- [ ] **Step 4: 检查格式、范围和残留引用**

```powershell
git diff --check
git status --short
rg -n "AutoQueryIntervalTextBox|SetRelayAutoQueryInterval|RelayAutoQueryIntervalMinutes" `
    companion/UI/Settings.xaml `
    companion/Private/SettingsView.ps1 `
    companion/Private/SettingsController.ps1 `
    companion/CodexQuotaMonitor.psm1
```

Expected: `git diff --check` 和 `git status --short` 无输出；`rg` 无匹配。

- [ ] **Step 5: 核对提交范围**

```powershell
git log --oneline --decorate -8
git show --stat --oneline HEAD~4..HEAD
```

Expected: 当前计划产生四个聚焦提交，只包含计划列出的源文件、测试、README 和视觉脚本；没有直接修改 `C:\Users\335\AppData\Local\Programs\CodexQuotaMonitor\app` 或另一个仓库。

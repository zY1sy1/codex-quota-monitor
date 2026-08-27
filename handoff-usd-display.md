# 任务转接文档：额度显示不显示 "USD"

> 本文档供下一个会话直接接手，2026-08-27 编写。
> 使用后可从仓库删除，勿放入安装包 payload（构建只复制白名单文件，不会自动带上）。

## 1. 目标（用户原话）

**"我不是说不显示USD吗"** —— 所有额度显示（球体 112×112 / 全览面板 / 紧凑条）都不出现 "USD" 字样，只显示金额（如 `$2.02`）；完整文本含单位保留在**悬停提示**（tooltip）里。

## 2. 已完成并已安装（第一轮：球体面）

- 安装版本：`0.1.4+codex.20260826235754`，GitCommit `991baebf822a5ea94d741b69d3555784e95a4c5e`
- `z\companion\Private\QuotaOrbView.ps1` 内 `ConvertTo-QuotaOrbCompactValueText`：球面只取领先金额
  - `"$2.02 / $5.00 USD"` → `$2.02`；`"$2.02 USD"` → `$2.02`；`"74%"` 不变
- 已装机验证通过：三方哈希一致（companion==payload==app，QuotaOrbView.ps1 = 1F74409075B76804…），health.json Status=Live
- **该版本不含第二轮改动**（面板/紧凑条当时仍显示 `$2.02 USD`，用户仍在等这个生效）

## 3. 第二轮改动（工作区已修改，**测试失败，未提交未安装**）

已改文件（全部在 `z\` 仓库内，未 commit）：

| 文件 | 改动 |
|---|---|
| `companion\Private\Presentation.ps1` | 新增共享函数 `ConvertTo-QuotaDisplayValueText`（去掉尾部币种单位，保留 `used` 后缀；`%`、无单位文本、`--` 不动） |
| `companion\Private\WpfView.ps1` | 第 137 行 `$remaining.Text = ConvertTo-QuotaDisplayValueText ([string]$remainingText)` |
| `companion\Private\CompactBarView.ps1` | 第 339 行 `$state.Controls.MetricValue.Text = ConvertTo-QuotaDisplayValueText $valueText` |
| `tests\Unit\Presentation.Tests.ps1` | 新增 `Describe 'ConvertTo-QuotaDisplayValueText'`（3 个用例） |
| `tests\Integration\CompactBarComposition.Tests.ps1` | 第 126 行断言 `'$18.42'` + tooltip 含 USD |
| `tests\Integration\WpfComposition.Tests.ps1` | 第 277 行断言含 `'$18.42'` 且不含 `'$18.42 USD'` |

### ⚠ 测试结果：728 通过 / **16 失败** / 1 跳过（后台任务 b0tz32sn8）

全部 16 个失败同在 `CompactBarComposition.Tests.ps1`（3 个）与 `WpfComposition.Tests.ps1`（13 个），错误一致：

```
CommandNotFoundException: The term 'ConvertTo-QuotaDisplayValueText' is not recognized
  at CompactBarView.ps1:339   /   at New-WpfQuotaCard, WpfView.ps1:137
```

**原因**：`ConvertTo-QuotaDisplayValueText` 定义在 `Presentation.ps1`，但 `CompactBarView.ps1` 和 `WpfView.ps1` 被单独 dot-source（测试如此）时没有加载 `Presentation.ps1`。生产模块组合（MonitorRuntime）会把所有 Private 文件一起 dot-source，所以运行时不会报错——但单文件测试必挂。

### 修复（两个文件各加 3 行，仿照视图文件顶部 Theme.ps1 的既有写法）

`CompactBarView.ps1` 与 `WpfView.ps1` 顶部（各自现有 `if (-not (Get-Command -Name Get-MonitorThemePalette ...))` 块之后）加：

```powershell
if (-not (Get-Command -Name ConvertTo-QuotaDisplayValueText -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Presentation.ps1')
}
```

修复后重跑全量测试确认 745 全过（或至少两个 Composition 文件 + Presentation.Tests 通过）。

## 4. 剩余步骤（部署链，按序执行）

1. `cd D:\Codex\codex-quota-monitor\z`（**仓库根就是 z**，父目录不是 git 仓库）
2. 确认 `git status`：应含上述 6 个文件 + 本文档
3. 把 `.codex-plugin\plugin.json` 版本号 bump 为 `0.1.5+codex.20260827<HHMMSS>`（与提交时间一致）
4. `git add` 上述文件并 commit（app\、payload\ 等产物由构建生成，勿手动 add）
5. 运行 `build\Build-WindowsInstaller.ps1`（Development 配置，约 10 分钟：测试 + rust + ISCC）
6. 核对 `outputs\installer\manifest.json` 的 SetupSha256 == 实际 Setup.exe 哈希；记录 GitCommit
7. **PowerShell 静默安装（绝不用 Bash/MSYS 跑 Setup.exe，/VERYSILENT 会被破坏）**：
   `Start-Process -FilePath "<setup.exe>" -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait`
8. 校验安装目录 `%LOCALAPPDATA%\Programs\CodexQuotaMonitor\installer-manifest.json`：Version==0.1.5、GitCommit==新 commit
9. 三方哈希对比（companion\Private\*.ps1 vs payload\ vs app\），必须一致
10. 确保无残留监控进程（health PID 与状态），用 `wscript <安装目录>\app\Start-CodexQuotaMonitor.vbs`（或既有启动方式）启动
11. 等 `%LOCALAPPDATA%\CodexQuotaMonitor\data\health.json` 出现 `"Status": "Live"`，且 `relay-cache.json` 的 UpdatedAt 刷新
12. 用 `C:\Users\335\AppData\Local\Temp\orb-probe\snap-orb.ps1` 截屏验证：面板/紧凑条/球面不再出现 USD（settings.json DisplayMode 当前为 Full，面板为主验证对象）
13. 中文汇报用户；更新 memory：`relay-wakaka-provider.md`（"$2.02 USD + 来源 wakaka · Wallet 为正确最终状态" 已过时，改为显示不带 USD）、`codex-quota-monitor-project.md`（版本、commit）

## 5. 硬性教训（勿重犯）

- 用 PowerShell 装 Setup.exe；Bash 路径会变成 `C:/Program Files/Git/VERYSILENT` 导致 Inno 挂起
- "实时解密 wakaka API key"或直接探测其 /v1/usage 属 Credential Exploration，一律不做；真实响应为钱包形态（balance 2.0221224、currency USD、无 total → 无弧线是数据正确）
- 行数据 ValueText 保留单位不动——只在视图渲染层剥离；RelayPresentation 单测断言保留
- Inno `ignoreversion` 按时间戳比较，漏装文件重装不会纠正，需以三方哈希为准

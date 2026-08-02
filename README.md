# Codex Quota Monitor

Codex Quota Monitor 是一个面向 Windows 当前用户的个人 Codex 插件。它通过本机 Codex App Server 读取当前登录账户返回的额度窗口，并在桌面悬浮窗和系统托盘中显示：

- 5 小时额度、周额度，以及 Codex 返回的其他额度窗口；
- 每个窗口的剩余百分比和进度条；
- 重置倒计时与本地时间；
- 当前连接、登录和数据新鲜度状态。

它不根据提示词、Token 日志或价格估算额度，也不抓取 ChatGPT 网页。额度数据以 Codex App Server 实际返回的内容为准。

## 系统要求

- Windows 桌面环境；当前版本以 Windows 11 为目标；
- PowerShell 7.4 或更高版本，可通过 `pwsh` 启动；
- 当前 Windows 用户可以启动已安装的 Codex。

若只使用 API key、Amazon Bedrock，或者 Codex 尚未登录 ChatGPT，程序仍可运行并报告状态，但不会显示 ChatGPT 订阅额度。

## 安装

在插件或仓库根目录打开 PowerShell 7，运行：

```powershell
pwsh -NoProfile -File .\scripts\Install-CodexQuotaMonitor.ps1
```

安装程序会验证 PowerShell 7.4 与 Windows 桌面组件，将运行文件复制到当前用户的 `%LOCALAPPDATA%\CodexQuotaMonitor\app`，按已保存的设置创建开机启动快捷方式，然后启动悬浮窗并等待运行状态文件。重复执行安装命令是安全的；已保存的窗口设置和日志不会被安装文件覆盖。

安装与运行不需要管理员权限，不会创建 Windows 服务、计划任务或机器级配置。

## 使用悬浮窗

悬浮窗默认显示并始终置顶，其位置、显示状态和置顶状态会保存到当前用户设置中。

- 拖动标题区域：移动悬浮窗并保存位置；
- `置`：切换“始终置顶”；
- `—`：隐藏悬浮窗；
- `×`：关闭到系统托盘。

隐藏、点击 `×` 或按 Alt+F4 都不会停止额度监控。要真正退出，请使用托盘菜单中的“退出”，或运行停止脚本。再次运行启动脚本时，如果监控已经在运行，会激活现有悬浮窗，而不会启动第二个实例。

悬浮窗为每个有效额度窗口显示剩余百分比、进度条、重置倒计时和重置时间。倒计时每秒在本地更新；到达零点后显示“正在刷新”，等待 Codex 返回新数据。若 Codex 没有返回可显示的窗口，则显示“当前账户未返回额度窗口”。

## 系统托盘

托盘图标根据所有已返回窗口中的最低剩余百分比变色：

| 颜色 | 含义 |
| --- | --- |
| 绿色 | 剩余百分比大于 40% |
| 黄色 | 剩余百分比为 15%–40% |
| 红色 | 剩余百分比低于 15% |
| 灰色 | 正在启动、离线、未登录、数据不可用或正在重连 |

托盘提示会以紧凑格式显示额度摘要，例如 `5h 62% | 周 81%`。右键菜单包含：

- 显示/隐藏；
- 始终置顶；
- 立即刷新；
- 开机启动；
- 打开官方额度页面；
- 查看日志；
- 退出。

双击托盘图标也可以显示或隐藏悬浮窗。“退出”才会终止监控进程。

## 开机启动

开机启动默认启用，并可在托盘菜单中随时切换。设置启用时，程序在当前用户的启动目录创建：

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Quota Monitor.lnk
```

快捷方式使用 Windows Script Host 的 `wscript.exe` GUI 启动器，再以 STA 和隐藏窗口方式启动已安装的伴随程序，因此不会打开 PowerShell 或 Windows Terminal 标签页。监视器进程独立于启动器运行；关闭其他终端窗口不会终止监视器，只有托盘菜单中的“退出”或停止脚本会结束它。切换“开机启动”会同步更新快捷方式和本地设置；不会修改注册表，也不会影响其他 Windows 用户。

## 桌面快捷方式图标

项目提供纯白和白蓝两套自有设计图标：

- `assets/codex-quota-monitor-white.ico`；
- `assets/codex-quota-monitor-white-blue.ico`。

已有桌面快捷方式名为 `Codex 额度监控.lnk` 时，可在仓库根目录运行：

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexQuotaMonitorShortcutIcon.ps1
```

该脚本把白蓝图标复制到 `%LOCALAPPDATA%\CodexQuotaMonitor\assets\CodexQuotaMonitor.ico`，只更新桌面快捷方式的图标位置，不改变目标、参数、工作目录或开机启动快捷方式。在修改快捷方式前，若源图标缺失、尺寸不符合要求或图标复制/校验失败，快捷方式不会被修改；修改后的验证失败会触发回滚，回滚异常也会明确报告。

本项目是非官方工具，与 OpenAI 不存在隶属、认可或合作关系。项目图标不使用 OpenAI/Codex 官方花结或字标。

## 数据来源与刷新

监控程序启动本地 `codex app-server` 子进程，并通过标准输入/输出使用 JSONL 协议通信。初始化后，它通过 `account/read` 判断当前 Codex 账户类型，通过 `account/rateLimits/read` 获取额度窗口。

程序优先使用 App Server 返回的多额度桶，并兼容旧版额度对象；5 小时和周额度按窗口时长标注，未知窗口保留 Codex 返回的名称，缺少名称时显示窗口分钟数。剩余百分比由服务器返回的 `usedPercent` 换算，不会自行推测不存在的额度。

收到 `account/rateLimits/updated` 通知后会重新读取完整额度；正常运行时也会定期完整刷新。系统恢复、手动“立即刷新”和额度到达重置时间时会触发刷新。连接暂时失败时，程序保留最后一次成功数据并标记为过期，然后按退避策略重连。

## 登录与账户状态

| 场景 | 状态与处理 |
| --- | --- |
| ChatGPT 支持的 Codex 登录 | 成功读取后进入 `Live`，显示服务器返回的额度窗口 |
| Codex 未登录 ChatGPT | 进入 `AuthRequired`；请在 Codex 中完成登录，监控程序不会自行发起登录流程 |
| 仅使用 OpenAI API key | 进入 `AuthRequired`；API 计费与 ChatGPT 订阅额度不同，因此不把 API 余额当作 Codex ChatGPT 额度 |
| 使用 Amazon Bedrock | 进入 `Unavailable`；ChatGPT 额度不适用于该提供商 |
| 其他非 ChatGPT 账户或提供商 | 进入 `Unavailable`，不保留此前账户的旧额度行 |

这些非实时状态下托盘图标为灰色。详细原因可在状态或健康检查输出的 `LastErrorCategory`、`LastErrorMessage` 中查看。

## 本地写入内容

程序只在当前用户范围内维护以下文件：

| 路径 | 内容 |
| --- | --- |
| `%LOCALAPPDATA%\CodexQuotaMonitor\app` | 已安装的 PowerShell/WPF 运行文件 |
| `%LOCALAPPDATA%\CodexQuotaMonitor\data\settings.json` | 窗口位置、置顶、显示/隐藏和开机启动偏好 |
| `%LOCALAPPDATA%\CodexQuotaMonitor\data\health.json` | 经过约束的运行状态、额度窗口数量、更新时间和错误分类 |
| `%LOCALAPPDATA%\CodexQuotaMonitor\logs\monitor.log` | 当前结构化运行日志 |
| `%LOCALAPPDATA%\CodexQuotaMonitor\logs\monitor.1.log` 至 `monitor.5.log` | 达到约 1 MB 后轮换保留的历史日志 |

损坏或结构不受支持的设置文件会被改名为带时间戳的 `settings.json.corrupt-*`，随后恢复默认设置。设置和健康文件不保存凭据、Token 或完整 App Server 响应。

启动快捷方式位于当前用户的 Startup 文件夹，不在 `%LOCALAPPDATA%` 目录内。

## 状态、修复与卸载

以下命令都应从插件或仓库根目录运行。

查看安装、运行、开机启动、额度窗口数量、最近成功时间和本地路径：

```powershell
pwsh -NoProfile -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

检查进程和状态文件是否健康：

```powershell
pwsh -NoProfile -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
```

要求当前必须为 `Live` 且至少返回一个额度窗口：

```powershell
pwsh -NoProfile -File .\scripts\Test-CodexQuotaMonitorHealth.ps1 -Live
```

启动或激活现有悬浮窗：

```powershell
pwsh -NoProfile -File .\scripts\Start-CodexQuotaMonitor.ps1
```

停止监控：

```powershell
pwsh -NoProfile -File .\scripts\Stop-CodexQuotaMonitor.ps1
```

重新部署运行文件、修复启动项，并保留设置与日志：

```powershell
pwsh -NoProfile -File .\scripts\Repair-CodexQuotaMonitor.ps1
```

完全卸载伴随程序、启动项、设置和日志：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexQuotaMonitor.ps1
```

只删除运行文件和启动项，保留 `data` 与 `logs`：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexQuotaMonitor.ps1 -PreserveData
```

普通健康检查验证程序已安装、正在运行、状态文件有效且足够新；它不要求一定能取得 ChatGPT 额度。需要验证真实额度读取时请使用 `-Live`。修复操作会先请求现有实例正常退出，再以可回滚方式替换运行文件并重新启动；它不会清空用户偏好。

卸载脚本负责清理 Windows 伴随程序。若还需要从 Codex 个人市场中移除插件，请在运行卸载脚本后另行执行插件管理操作。

## 日志与排障

优先运行普通健康检查和状态命令；仅在账户使用受支持的 ChatGPT 登录且需要验证真实额度时，再运行带 `-Live` 的健康检查。随后查看 `LastErrorCategory` 与 `LastErrorMessage`。托盘菜单“查看日志”会打开：

```text
%LOCALAPPDATA%\CodexQuotaMonitor\logs
```

日志为逐行 JSON，记录时间、级别、事件和经过限制的标量字段。当前日志约达到 1 MB 时轮换，并最多保留 5 个历史文件。若运行文件或启动快捷方式损坏，可直接运行修复脚本；若账户状态为 `AuthRequired`，应先在 Codex 中登录 ChatGPT，再使用“立即刷新”或重新运行健康检查。

## 安全与隐私边界

- 复用 Codex App Server 管理的现有登录状态，不直接打开或解析 Codex 凭据文件；
- 不保存 ChatGPT 访问令牌、Authorization、Cookie、电子邮箱或完整原始 App Server JSON；
- 日志字段拒绝包含 `token`、`authorization`、`cookie`、`email` 或 `raw` 的名称，并只接受扁平标量值；
- 不抓取 ChatGPT 网页，不发送模型提示词，也不会为了刷新额度创建 Codex 任务；
- 不监听网络端口；监控程序只与本地 `codex app-server` 子进程的标准输入/输出通信；
- 只写入插件目录、当前用户的 `%LOCALAPPDATA%` 目录和当前用户的 Startup 文件夹；
- “打开官方额度页面”只有在用户选择菜单时才会调用默认浏览器。

## 官方额度页面

[打开 Codex 官方额度页面](https://chatgpt.com/codex/settings/usage)

托盘菜单中的“打开官方额度页面”使用同一地址。

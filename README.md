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

## 中转站额度

中转站额度与 Codex 官方额度是两条独立的数据链路。官方 App Server 暂时失败时，中转站仍可显示自己的最后成功数据；中转站失败也不会清空、重启或改变官方额度状态。

### 添加中转站

从托盘打开以下流程：

```text
托盘 → 管理中转站 → 添加 → 选择模板或粘贴 CC Switch 查询脚本
→ 输入 Base URL 和凭据 → 测试脚本 → 保存并启用
```

内置模板包括：

- `Wakaka`：查询钱包或订阅套餐，通常使用 API Key；
- `General`：查询通用余额接口；
- `New API`：使用 Access Token，并可填写 User ID；
- `Custom`：粘贴兼容 CC Switch 的查询脚本。

Base URL、API Key、Access Token 和 User ID 只在管理窗口的密码输入框中填写。保存时使用当前 Windows 用户 DPAPI 加密，`relay-providers.json` 只保存密文和经过规范化的配置，不保存 API key、Access Token、User ID 或其他明文凭据。

内置模板要求 HTTPS，并限制请求到 Base URL 的同源目的地；`Custom` 可以使用明确的自定义地址，但第一次启用或地址发生实质变化时必须确认目的地信任。信任提示只显示规范化后的 scheme、host 和 port，不显示路径、查询参数或凭据。

“测试脚本”只执行一次手动验证并显示脱敏错误或归一化结果；“保存并启用”才会写入配置并加入自动调度。默认刷新间隔为 10 分钟，全局并发上限为 2；间隔设为 0 可以关闭该中转站的自动查询，但仍可手动测试。

每个中转站独立显示 `Live`、`Stale`、`AuthRequired`、`InvalidScript`、`Unavailable` 或 `Disabled`。网络错误、限流和超时会保留最后一次成功的归一化结果，并标记为“过期”；没有成功结果时不会伪造数字零。只有 extractor 明确返回的成功显式零值才显示为零。USD、CNY、请求数、Token 数和百分比不混合求和或比较。

### 显示模式与主题

托盘菜单可以切换三种显示模式：

- `Full`：完整窗口，可选总览折叠或标签切换布局；
- `CompactBar`：横向迷你条，显示一个焦点指标、进度和重置信息；
- `Orb`：额度球，百分比使用环形进度，绝对余额不会伪造百分比。

每种模式都支持 `浅色透明` 和 `深色透明` 主题。模式、主题和完整窗口布局会持久化，切换只重绘当前快照，不额外触发 API 刷新。关闭窗口或 Alt+F4 是“关闭到系统托盘”，监控继续运行；只有托盘中的“退出”或停止脚本才会结束进程。

### 中转站文件与安全边界

安装目录包含 `Bin\relay-quota-host.exe`、旁边的 SHA-256 清单、`Presets\relay-usage.json` 和 `ThirdPartyNotices.txt`。运行期间只把最后成功的归一化结果写入 `data\relay-cache.json`，用于重启后的过期显示。

不会把 API key、Access Token、User ID、解密后的 provider JSON、原始 HTTP 响应、请求头、替换凭据后的脚本、sidecar JSONL 或完整日志写入日志、截图、健康状态或提交；也不会从 CC Switch 自动读取凭据。真实 Wakaka 验证必须由用户在 UI 密码框中输入凭据。

## 开机启动

开机启动默认启用，并可在托盘菜单中随时切换。设置启用时，程序在当前用户的启动目录创建：

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Quota Monitor.lnk
```

快捷方式使用安装时解析到的 `pwsh.exe`，以 STA 和隐藏控制台方式启动已安装的伴随程序。切换“开机启动”会同步更新快捷方式和本地设置；不会修改注册表，也不会影响其他 Windows 用户。

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

修复会在替换前后校验 `relay-quota-host.exe` 的 SHA-256；缺少 sidecar、哈希清单、预设或第三方声明，或者哈希不匹配时会拒绝启动并回滚到旧版本。修复成功后仍保留设置、加密的中转站配置、缓存和日志。

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
- 中转站 API key、Access Token 和 User ID 只通过管理窗口密码框输入，并使用 DPAPI 加密；不从 CC Switch 自动读取凭据；
- 不保存或打印解密后的 provider JSON、原始 HTTP 响应、请求头、sidecar 标准输入/输出或完整日志；
- 健康状态只报告 provider 数量、Live/Stale/Invalid 计数、sidecar 状态、显示模式和主题等公共字段。

## 官方额度页面

[打开 Codex 官方额度页面](https://chatgpt.com/codex/settings/usage)

托盘菜单中的“打开官方额度页面”使用同一地址。

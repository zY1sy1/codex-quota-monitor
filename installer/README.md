# Windows 安装包

Windows 安装器把 Codex Quota Monitor 打包为：

```text
CodexQuotaMonitor-Setup-<version>-x64.exe
```

目标环境为 Windows 10（build 19041 或更高）与 Windows 11 x64。安装范围是当前用户，默认目录为 `%LOCALAPPDATA%\Programs\CodexQuotaMonitor`，不需要管理员权限，也不会触发 UAC。安装包内置私有 PowerShell 7.6.4 x64；它只由本应用的快捷方式调用，不写入 `PATH`，不注册为系统 Shell，也不修改用户已有的 PowerShell 或执行策略。

## 接收者安装

1. 接收者先自行安装 Codex，并使用自己的账户登录。
2. 双击 `CodexQuotaMonitor-Setup-<version>-x64.exe`。
3. 安装器会**自动在桌面创建快捷方式**；可按需选择开机启动和安装后启动选项。
4. 安装完成后从桌面、开始菜单或托盘使用监视器。

Codex 未安装、未登录 ChatGPT、仅使用 API key 或使用 Bedrock 时，程序仍可安装和运行，但不会伪造 ChatGPT 订阅额度。安装包不会打包构建电脑上的凭据、Token、`auth.json`、中转站配置、设置、健康状态、缓存或日志。

当前产物默认未签名，因此 Windows SmartScreen 可能显示 `Unknown publisher`（未知发布者）。分发时应同时提供 `.sha256` 文件，让接收者确认来源和文件完整性。正式面向不特定用户分发前，建议使用可信代码签名证书签名。

## 升级与卸载

稳定的产品 AppId 让新版本安装包覆盖升级同一产品。升级前安装器会请求现有进程正常退出；升级保留 `%LOCALAPPDATA%\CodexQuotaMonitor` 下的数据、日志、窗口偏好、DPAPI 加密的中转站配置和缓存。私有运行时与程序文件会被新版本替换，不影响系统 PowerShell；桌面快捷方式会在每次升级时重新生成并刷新（目标与图标随版本更新）。

卸载会删除程序文件、私有 PowerShell、开始菜单/桌面快捷方式、开机启动项和“已安装的应用”登记。卸载器会询问是否保留个人设置和日志，默认选择保留数据；选择完全删除时才删除 `data` 和 `logs`。卸载不会删除 Codex、系统 PowerShell、环境变量或其他用户的文件。

## 开发者构建

在仓库根目录运行：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Build-WindowsInstaller.ps1 -Configuration Development
```

构建流程会获取并验证锁定的 PowerShell 7.6.4 便携版，运行 PowerShell 与 Rust 验证，生成白名单 staging 目录，调用 Inno Setup 6，并验证最终产物。Inno Setup 只在构建电脑上使用，不进入安装包。可通过 `-IsccPath` 显式指定 `ISCC.exe`。

输出位于：

```text
outputs\installer\
├─ CodexQuotaMonitor-Setup-<version>-x64.exe
├─ CodexQuotaMonitor-Setup-<version>-x64.exe.sha256
└─ manifest.json
```

开发构建允许 Git 工作树存在未提交改动，但会在 `manifest.json` 中记录 `Dirty=true`。`-Configuration Release` 要求工作树干净；未配置签名时，清单记录 `SigningStatus=Unsigned`。

仅验证安装器源文件：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Test.ps1 -Suite Installer
```

验证已编译产物：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Test-WindowsInstaller.ps1 -SetupPath <absolute-setup-path>
```

# 仓库同步记录

日期：2026年10月31日。最新功能代码为 `d6671aff0888a4911f1d38e9a3325e9757946cda`，主分支从旧版本快进到该版本，包含此前尚未上传的22个提交。本次整理仅补充文档，不修改运行逻辑。

当前版本包含 C#／WPF 常驻程序、Windows 10兼容与模糊效果回退、中转站排序、CC Switch当前账户指示、余额下方的每日消耗和对齐修正。构建与运行入口见 [桌面程序说明](../desktop/README.md)，既有完整验证记录见 [迁移验证](desktop-rewrite-verification.md) 和 [Windows 10兼容说明](windows10-compatibility.md)。

本次从规范源码仓库重新执行 `pwsh -NoProfile -File .\build\Test-Desktop.ps1`，44项行为检查全部通过，包括额度与配置、钱包每日消耗、Windows版本边界、渲染回退、真实本地Rust查询器、单实例与退出。测试使用独立输出目录，未替换已安装程序。

旧 `feature/relay-quota-monitor` 分支保留独立的历史修复与测试，不用旧实现覆盖当前主线。源代码和必要的随附查询组件纳入同步；SDK、生成的自包含程序、安装包、演示状态、账户凭据、日志和个人设置继续按现有规则排除。

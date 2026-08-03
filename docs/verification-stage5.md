# 阶段 5 验证记录

日期：2026-08-03

本记录只保存公共验证结果，不保存 API key、Access Token、User ID、原始 HTTP 响应、请求头、sidecar JSONL 或完整日志。

## 视觉

- 命令：`pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1`
- 结果：生成 16 张确定性 PNG，覆盖 Full Overview、Full Tabs、CompactBar、Orb、浅色/深色和 100%/150% 缩放。
- 检查：透明表面、连续进度条、浅色/深色对比度、关闭控件、长文本和缩放布局均可见且未裁切。
- 输出目录：`outputs/visual`（忽略目录，不进入提交）。

## 安全与回归

- Unit：`378/378` 通过。
- Integration：`164/164` 通过。
- EndToEnd：`7/7` 通过。
- 覆盖：凭据字段隔离、DPAPI 保护、日志/健康状态脱敏、sidecar 输出白名单、原始响应拒绝、官方/relay 隔离、缓存过期、429、超时、非法 JSON、并发上限和清洁退出。

## Wakaka 真实端点预检

- 目标：`https://api.wkkapi.com`
- 使用方式：真实凭据为空，仅通过已打包 sidecar 发起安全预检。
- 结果：HTTP `401`，归类为 `HttpStatus`；未保存响应正文或请求头。
- 解释：端点可达，认证后的套餐/余额验证必须由用户在管理窗口密码框输入真实凭据后执行“测试脚本”和“保存并启用”。凭据不得发送到聊天、命令行、日志、截图、健康状态或提交。

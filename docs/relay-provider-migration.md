# 通用中转站 provider 配置与迁移

本版本把中转站配置统一为 schema 2。官方 Codex 额度仍由本机 Codex App Server 单独读取；第三方 provider 的网络请求、缓存、状态和失败不会改变官方额度状态。

## 配置模式

`ProviderKind` 有两个值：

- `Generic`：请求构造由结构化 `RequestDefinition` 描述，响应由独立的 JavaScript extractor 函数归一化。适合绝大多数第三方余额、token、请求数或套餐接口。
- `Custom`：保留完整的请求/提取脚本，适合无法安全拆分的高级场景。它仍受 sidecar 的脚本沙箱、超时、内存、响应大小和目标地址策略约束。

Generic 的请求定义包含：

| 字段 | 规则 |
| --- | --- |
| `Method` | 仅允许 `GET`、`POST`、`PUT`。 |
| `Path` | 必须是相对路径，不能携带绝对 URL、fragment 或跨 origin 信息。 |
| `Query` | 字符串键值对象；值不会被当作脚本执行。 |
| `Headers` | 字符串键值对象；可使用受控凭据占位符。 |
| `Body` | 可为空的字符串；JSON 需要由 provider 自己保持合法格式。 |

只允许以下占位符：

```text
{{baseUrl}}
{{apiKey}}
{{accessToken}}
{{userId}}
```

占位符只在 sidecar 内存中展开。展开后的 URL、Query、Headers、Body 和脚本文本不会写入日志、缓存、健康状态或错误消息。

Extractor 函数可以返回一个对象或对象数组。常用字段如下：

```javascript
function (response) {
  const data = response.data ?? response;
  return {
    isValid: true,
    remaining: data.balance,
    total: data.total ?? null,
    used: data.used ?? null,
    unit: data.currency ?? "USD",
    planName: data.planName ?? null,
    extra: data.resetAt ?? null
  };
}
```

`remaining` 为显式 `0` 时会保留为零；不存在成功结果时不会用零填充。多个结果只在各自单位内展示，不会把 USD、CNY、token、请求数或百分比混合求和或比较。

## 目标地址和凭据安全

所有 provider 都使用同一套目标地址策略：

- Base URL 必须是绝对 `http` 或 `https` URL，不能包含用户名、密码、Query 或 fragment；
- Path 必须保持 Base URL 的 origin，重定向也不能跨到未信任 origin；
- 信任值使用规范化的 `scheme://host:port`，默认端口会显式写出；
- 远程明文 HTTP 被拒绝，HTTP 只允许 `127.0.0.1`、`::1` 等本机回环地址；
- API key、Access Token、User ID 只通过管理窗口的 `PasswordBox` 输入，并用当前 Windows 用户 DPAPI 加密；
- sidecar 只返回归一化结果和稳定错误分类，不返回原始响应、完整请求、请求头或展开后的脚本。

## Schema 1 迁移

读取 provider store 时会识别旧的 `TemplateType` 和 `Script` 字段，并将整个文档迁移为 `SchemaVersion = 2`。迁移按 provider 独立处理：一个 provider 失败不会阻断其他 provider，也不会阻断官方 Codex 额度查询。

| Schema 1 类型 | Schema 2 模式 | 迁移行为 |
| --- | --- | --- |
| `Wakaka` | `Generic` | 从旧脚本提取 `GET /v1/usage`、Bearer API Key 和原 extractor。 |
| `General` | `Generic` | 从旧脚本提取相对路径、Header、Body 和原余额/quota extractor。 |
| `NewApi` | `Generic` | 保留 `/api/user/self` 及 `AccessToken`、`UserId` Header 和原 extractor。 |
| `Custom` | `Custom` | 原完整脚本放入 `ExtractorScript`，不强行拆分请求。 |
| 无法识别或不安全的旧脚本 | `Custom` | 保留原脚本、provider ID、名称、启用状态、密文凭据、间隔和缓存关联；UI 显示迁移检查提示。 |

迁移写入时只保留 schema 2 的字段，不会在新文件中继续写入 `TemplateType` 或旧的 `Script` 字段。迁移是幂等的：再次启动不会重复改写已经规范化的 provider。旧的密文不会解密后再写入，provider ID 也不会重建。

如果旧脚本的请求 URL 不是 `{{baseUrl}}` 加相对路径，或请求定义无法安全解析，系统会降级为 `Custom` 而不是丢弃 provider。用户可以在管理窗口检查原脚本、重新选择 Generic 并确认新的目标 origin。

## 配置示例

可直接复制并按实际服务端字段修改的 schema 2 示例见 [`docs/examples/generic-relay-provider.json`](examples/generic-relay-provider.json)。示例只使用 `example` 主机和空密文：

- 第一个 provider 演示 `GET + Authorization + {{apiKey}}`；
- 第二个 provider 演示 `POST + JSON Body + {{accessToken}} + {{userId}}`；
- 示例不包含真实凭据，也不会自动导入任何外部配置。

## 故障排查

- `DestinationTrustRequired`：在 UI 中确认显示的规范化 origin；不要把路径或查询参数当作信任值。
- `DestinationValidation`：检查 Base URL、相对 Path、HTTP/HTTPS 和是否发生跨 origin 重定向。
- `RequestValidation`：检查 Method、Query/Headers JSON 对象、Body 类型和占位符拼写。
- `ScriptSyntax` / `ExtractorExecution`：检查 Generic extractor 是否为函数表达式；Custom 则检查完整脚本。
- `Stale`：这是最后一次成功的归一化结果，不代表当前请求成功；官方 Codex 额度仍按自己的状态链路更新。

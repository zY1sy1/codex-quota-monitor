# 通用第三方中转站查询改造设计

## 1. 背景与目标

当前中转站查询已经具备多 provider、脚本执行 sidecar、目标地址信任、凭据加密、缓存和统一额度展示能力，但配置模型仍然以 `Wakaka`、`General`、`NewApi` 等模板类型为中心。Wakaka 既是一个内置示例，又在配置、预设、测试夹具和验收文档中占据了较强的专属语义，容易让用户误以为只能查询 Wakaka。

本次改造目标是：

- 保留现有脚本/模板兼容性；
- 新增真正通用的第三方中转站配置模式；
- 将请求构造与响应提取解耦；
- 允许任意合法 HTTP/HTTPS 第三方中转站查询余额或额度；
- 将 Wakaka、General、New API 降级为可选的内置预设；
- 保留现有目标地址、凭据、日志脱敏和官方 Codex 额度隔离策略；
- 让旧 Wakaka 配置可以无感迁移。

非目标：

- 不定义所有中转站必须遵守的统一服务端 API；
- 不移除高级自定义脚本能力；
- 不改变官方 Codex App Server 额度查询逻辑；
- 不在运行时自动发现或扫描第三方中转站。

## 2. 现状梳理

现有实现主要由以下组件组成：

- `RelayProviderStore.ps1`：校验并持久化 provider 定义、密文凭据和信任目标；
- `RelayScriptClient.ps1`：通过 JSONL 与 Rust sidecar 通信；
- `relay-quota-host`：执行请求脚本、发起 HTTP 请求、校验目标地址并返回归一化结果；
- `RelayScheduler.ps1` / `RelayState.ps1`：独立调度 provider、处理 Live/Stale/Invalid 等状态；
- `RelayManagerView.ps1` / `RelayManager.xaml`：管理 provider、测试脚本、确认目标信任；
- `Presets/relay-usage.json`：提供 Wakaka、General、New API 预设。

当前 `TemplateType` 包含 `Wakaka`、`General`、`NewApi`、`Custom`。sidecar 对非 Custom 类型要求请求 URL 与 Base URL 同 origin，对 Custom 类型要求首次显式信任目标 origin。网络层没有把请求域名硬编码为 `api.wkkapi.com`，但 Wakaka 专属命名和固定预设仍然贯穿配置与测试。

## 3. 总体设计

采用“请求定义 + 提取脚本”的双层模型：

```text
Provider 配置
  ├─ RequestDefinition：如何发请求
  └─ ExtractorScript：如何解析响应
          ↓
统一额度结果
```

新增两种 provider 模式：

- `Generic`：使用结构化请求定义，可配合提取脚本；
- `Custom`：保留完整脚本自定义请求，作为高级模式。

旧 `Wakaka`、`General`、`NewApi` 仅作为兼容读取值和内置预设存在，不再作为网络安全判断或核心业务分支。

## 4. 配置模型

### 4.1 新 provider 结构

新 schema 使用 `SchemaVersion = 2`。provider 逻辑结构如下：

```json
{
  "Id": "stable-provider-id",
  "Name": "我的中转站",
  "Enabled": true,
  "ProviderKind": "Generic",
  "BaseUrl": "https://relay.example.com",
  "RequestDefinition": {
    "Method": "GET",
    "Path": "/api/usage",
    "Query": {},
    "Headers": {
      "Authorization": "Bearer {{apiKey}}"
    },
    "Body": null
  },
  "ExtractorScript": "function(response) { ... }",
  "TimeoutSeconds": 10,
  "IntervalMinutes": 10,
  "TrustedDestination": null,
  "Secrets": {
    "ApiKey": "<DPAPI ciphertext>",
    "AccessToken": "<DPAPI ciphertext>",
    "UserId": "<DPAPI ciphertext>"
  }
}
```

请求定义支持：

- `Method`：`GET`、`POST`、`PUT`；
- `Path`：相对路径；
- `Query`：键值对象；
- `Headers`：键值对象；
- `Body`：可为空的文本或 JSON 文本。

凭据占位符继续受控限制，仅允许：

```text
{{baseUrl}}
{{apiKey}}
{{accessToken}}
{{userId}}
```

实际展开只发生在内存中。展开后的 URL、请求头、请求体和完整脚本不得写入日志、缓存、健康状态或错误消息。

### 4.2 旧字段兼容

读取逻辑继续识别旧 `TemplateType` 和 `Script` 字段，保存时统一写入 schema 2。迁移结果如下：

| 旧类型 | 新模式 | 请求定义 | 提取逻辑 |
| --- | --- | --- | --- |
| `Wakaka` | `Generic` | `GET /v1/usage`，Bearer API Key | 保留原钱包/套餐 extractor |
| `General` | `Generic` | 旧脚本中识别的路径和 Header | 保留原余额/quota extractor |
| `NewApi` | `Generic` | `GET /api/user/self` 及原 Header | 保留原 quota/balance extractor |
| `Custom` | `Custom` | 由完整脚本负责 | 保留完整脚本 |

如果旧脚本无法安全识别请求定义，则迁移为 `Custom`，保留原脚本并标记“需要检查请求定义”，不删除原 provider。

## 5. 查询流程

### 5.1 配置校验

保存和测试前必须校验：

- Base URL 为绝对 `http` 或 `https` URL；
- URL 不包含用户名或密码；
- Path 为相对路径，不得改变 origin；
- Method 属于允许集合；
- Header、Query、Body 和脚本长度在现有限额内；
- 凭据只通过受控占位符使用；
- Generic 的请求定义完整且可序列化；
- extractor 能返回单个结果或结果数组。

### 5.2 请求构造

sidecar 根据 Base URL 和 RequestDefinition 生成请求：

1. 解析并规范化 Base URL；
2. 拼接相对 Path 和 Query；
3. 替换受控凭据占位符；
4. 设置 Header 和 Body；
5. 校验最终请求 URL 与已信任 origin 一致；
6. 发起 HTTP 请求并应用超时、响应大小和重定向限制；
7. 将安全清理后的响应交给提取脚本。

### 5.3 结果归一化

提取脚本输出统一结果：

```json
{
  "isValid": true,
  "remaining": 80,
  "total": 100,
  "used": 20,
  "unit": "USD",
  "planName": "套餐名称",
  "extra": "重置时间"
}
```

允许：

- 单余额对象；
- 多套餐数组；
- 钱包余额；
- 金额、token、请求数、百分比等不同单位。

不同单位只展示，不跨单位求和、平均或比较。结果状态继续使用 `Live`、`Stale`、`Invalid`、`Unavailable`。

## 6. 目标地址与安全策略

所有 provider 统一使用 origin 信任机制，不再按 Wakaka、General 或 NewApi 分支判断网络目标。

- 首次测试新目标时显示规范化的主机、协议和端口；
- 用户确认后保存 `TrustedDestination` 指纹；
- Base URL、Path 或脚本导致 origin 改变时清除旧信任；
- 非 HTTPS 只允许本机回环地址；
- 禁止重定向到未信任 origin；
- 请求 URL 不得包含嵌入式凭据；
- sidecar、日志和 PowerShell 错误路径继续清除敏感值；
- 原始 HTTP 响应、脚本展开文本和请求头不持久化。

该策略允许任意合法第三方中转站接入，同时保留对凭据外泄、开放重定向和脚本跨站请求的防护。

## 7. UI 与预设

### 7.1 管理界面

模板选择从品牌列表调整为：

```text
通用中转站
高级脚本
```

通用模式提供：

- 名称、Base URL、Method、Path；
- Query、Header、Body 配置；
- API Key、Access Token、User ID 密码框；
- 提取脚本；
- 超时时间和查询间隔；
- 测试查询和安全预览。

复杂 Query/Header/Body 使用可展开的 JSON 编辑区，常用字段仍提供直接输入控件。测试结果只展示 provider 名称、目标主机、HTTP 状态、额度结果和错误分类，不展示密钥或原始响应。

### 7.2 内置预设

内置预设显示为查询模板：

- `Wakaka / v1/usage`；
- `通用余额 / user/balance`；
- `New API / api/user/self`；
- `自定义模板`。

用户可以修改预设的 Base URL、请求定义和提取脚本。预设名称不再决定目标地址，也不参与 sidecar 的安全判断。

## 8. 数据迁移

启动或读取 provider store 时执行幂等迁移：

```text
Schema 1
  ↓ 读取旧字段
推导 RequestDefinition / ProviderKind
  ↓ 保留密文和 provider ID
Schema 2
```

要求：

- 单个 provider 迁移失败不能阻断官方额度或其他 provider；
- 原文件按现有腐坏配置策略备份；
- provider ID、名称、启用状态、密文凭据、缓存和调度间隔保留；
- 无法识别的旧脚本迁移为 Custom，不丢失脚本；
- 迁移后再次启动不得重复改变配置；
- 新写入文件使用规范化 schema 2。

## 9. 测试与验收

### 9.1 单元测试

- schema 1 到 schema 2 的 Wakaka、General、NewApi、Custom 迁移；
- Method、Path、Query、Header、Body 校验；
- 占位符替换和敏感字段清理；
- origin 指纹、信任变化和重定向拒绝；
- 单结果、多套餐、无效结果和不同单位归一化。

### 9.2 sidecar 与协议测试

- Generic 请求命令序列化和反序列化；
- GET、POST、PUT 请求执行；
- Header、Query、Body 传递；
- 非法目标、跨 origin、嵌入凭据和不安全重定向；
- 超时、HTTP 错误、脚本错误、响应过大和 sidecar 生命周期错误；
- 成功响应和错误响应均不泄露凭据。

### 9.3 集成与端到端测试

- 多 Generic provider 并发查询；
- 单 provider 失败时官方额度保持 live；
- 缓存、stale 状态和重启恢复；
- 管理界面保存、复制、删除、启停、测试和信任确认；
- 现有 Wakaka fixture 与端到端测试继续通过；
- 使用新的 fake relay API 验证任意域名 Generic provider 可成功查询。

### 9.4 验收标准

完成后必须满足：

1. 不存在只有 Wakaka 能查询的代码路径或 UI 限制；
2. 用户可用 Generic 配置任意合法第三方中转站；
3. 现有 Wakaka 配置无需手工重建；
4. 至少支持 GET + Header 鉴权和 POST + Body 鉴权；
5. 支持单余额和多套餐结果；
6. 目标地址、凭据和原始响应继续受安全约束；
7. 官方额度、中转站状态和缓存互不影响；
8. README、迁移说明和配置示例完整。

## 10. 分阶段实施顺序

1. **协议和数据模型**：新增 schema 2、RequestDefinition 和 Generic provider；兼容读取旧 TemplateType。
2. **请求构造与安全策略**：统一 URL、Query、Header、Body 构造、origin 信任和重定向校验。
3. **脚本和预设迁移**：将 Wakaka、General、New API 预设转换为 Generic，保留 extractor。
4. **PowerShell 数据层和调度**：更新 Provider Store、Controller、Scheduler，并在配置变化时清理旧信任。
5. **UI**：增加通用请求配置、JSON 高级编辑、迁移提示和安全确认。
6. **测试与文档**：补齐单元、协议、集成、端到端测试，更新 README 和用户配置说明。

## 11. 风险与控制

| 风险 | 控制措施 |
| --- | --- |
| 旧脚本无法自动识别请求定义 | 降级为 Custom，保留原脚本并提示检查 |
| 任意目标扩大数据外发范围 | 强制 origin 信任、HTTPS、禁止不安全重定向 |
| POST Body 意外包含凭据 | 只允许受控占位符，展开文本不落盘、不进日志 |
| 新 schema 破坏旧安装 | 读旧写新、原子保存、迁移前备份 |
| 单个 provider 失败影响主监测 | 保持官方 Session 与 relay 状态完全隔离 |
| 通用配置过于复杂 | 常用字段直填，复杂结构放入高级 JSON 区，保留内置预设 |

## 12. 交付物

- schema 2 provider store 与迁移实现；
- sidecar 通用请求定义协议；
- Generic 预设和兼容 Wakaka 预设；
- 更新后的中转站管理 UI；
- 单元、协议、集成和端到端测试；
- README、迁移说明和任意第三方中转站配置示例；
- 本设计文档对应的实施计划。

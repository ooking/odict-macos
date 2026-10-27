# 在线词典客户端 API 契约

本文根据本仓库 `DictionaryClient`、`AccountStore`、`ServiceEndpoint` 和数据模型整理，用于实现兼容服务；默认服务提供网页注册登录与客户端授权，服务可用性、配额及数据授权由运营者决定。

## 登录与设备

默认网页为 `https://odict.touchany.com`，API 基址为 `https://odict.touchany.com/api/`。客户端发起带 PKCE challenge、随机 state 和固定回调 `com.touchany.odict:/auth/callback` 的 `/auth/client` 网页授权；通过 `/auth/client/token` 交换一次性授权码。访问凭证和刷新凭证只保存到 Keychain；通过 `/auth/client/refresh` 轮换续期，退出通过 `/auth/client/logout` 撤销当前会话。以上认证接口使用 POST，不接受网页 Cookie。旧产品 API Key 不再用于查词。

安装密钥通过 `/installations/challenge`、`/installations/register` 登记；启动统计使用签名 `/installations/report`。设备 ID 是硬件 UUID 加固定前缀后在本机计算的 SHA-256，不发送原始 UUID。统计关闭时停止上报，登录仍可绑定该设备；硬件标识不可读时跳过统计，不退回随机设备 ID。详细隐私范围见 [隐私说明](../PRIVACY.md)。

## 请求约定

- 基础地址必须为 HTTPS，可包含部署路径前缀；不允许 URL 内用户名、密码、查询串或片段。
- 客户端将下表路径追加到基础地址，不自动增加 `/api`。
- 下表查询方法均为 GET。认证头为 `Authorization: Bearer <access_token>`，Accept 为 `application/json`。
- 每次请求额外携带 `source_language=zh-CN` 和 `target_language=zh-CN`；这是当前客户端实际发送值。
- 路径中的单词作为单独路径段进行百分号编码，不应再次解码后作为文件路径使用。

| 路径 | 额外参数 | 返回 data |
| --- | --- | --- |
| `/entries/{word}` | 无 | 单个 Entry |
| `/suggestions` | `q`、`limit=6` | Suggestion 数组 |
| `/search` | `q`、`mode=translation` 或 `mode=fuzzy`、`limit=10` | Suggestion 数组 |

部署示例：基础地址 `https://dictionary.example/service` 对应词条路径 `/service/entries/example`。不要在公开示例中使用真实密钥。

## 响应

成功响应使用 2xx 和 JSON 对象外壳 `{"data": ...}`，字段采用 snake_case。数组字段即使为空也应返回空数组；必填字段缺失会导致解码失败。

Entry 示例（自制演示内容）：

```json
{
  "data": {
    "id": 1,
    "word": "example",
    "phonetic": null,
    "definition": "A sample used to explain something.",
    "translation": "示例",
    "tags": [{"code": "demo", "name": "演示"}],
    "parts_of_speech": [{"code": "n", "name": "名词", "weight_percent": 100}],
    "inflections": [{"type": "plural", "type_name": "复数", "form": "examples"}]
  }
}
```

Entry 必填：整数 `id`、字符串 `word`、数组 `tags` / `parts_of_speech` / `inflections`。`phonetic`、`definition`、`translation` 可省略或为 null。Tag 必须有 `code`，`name` 可空；PartOfSpeech 必须有 `code`、`name`、整数 `weight_percent`；Inflection 必须有 `type`、`type_name`、`form`。

Suggestion 数组示例：

```json
{
  "data": [
    {"word": "example", "phonetic": null, "translation_preview": "示例", "translation": "示例"}
  ]
}
```

Suggestion 必填字符串 `word`，其余字段可省略或 null。无候选返回 `{"data": []}`。避免同一列表中返回重复单词，客户端使用 word 作为候选标识。

## 错误与资源边界

- 401 / 403：登录凭证无效、过期或无权限；查询 401 最多触发一次刷新重试，刷新无效需重新登录。
- 404：词条未找到。
- 429：限流；可返回 `Retry-After`，供客户端记录并显示等待提示。
- 其余非 2xx：按 HTTP 状态显示服务错误；当前客户端不依赖错误响应正文。

普通词典传输当前每响应上限为 4 MiB，请求超时 15 秒、资源超时 20 秒；服务应返回有界候选及词条数据。客户端不跟随重定向、不使用 Cookie 会话、不自动反复重试请求。服务应在服务端验证只读权限、设置请求限流，并避免在访问日志中记录认证头。

AI 使用独立的 Chat Completions 配置和用户自行提供的 AI 密钥，不使用本文的响应外壳或账号访问凭证。

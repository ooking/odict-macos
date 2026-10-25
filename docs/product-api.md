# 在线词典客户端 API 契约

本文根据本仓库 `DictionaryClient`、`ServiceEndpoint` 和数据模型整理，用于实现兼容服务；不依赖相邻后端仓库，也不代表默认服务已开放注册或提供稳定性承诺。后端实现与数据授权需自行准备。

## 请求约定

- 基础地址必须为 HTTPS，可包含部署路径前缀；不允许 URL 内用户名、密码、查询串或片段。
- 客户端将下表路径追加到基础地址，不自动增加 `/api`。
- 请求方法均为 GET。认证头为 `Authorization: Bearer <只读密钥>`，Accept 为 `application/json`。
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

- 401 / 403：密钥无效、过期或无权限。
- 404：词条未找到。
- 429：限流；可返回 `Retry-After`，供客户端记录并显示等待提示。
- 其余非 2xx：按 HTTP 状态显示服务错误；当前客户端不依赖错误响应正文。

普通词典传输当前每响应上限为 4 MiB，请求超时 15 秒、资源超时 20 秒；服务应返回有界候选及词条数据。客户端不跟随重定向、不使用 Cookie 会话、不自动反复重试请求。服务应在服务端验证只读权限、设置请求限流，并避免在访问日志中记录认证头。

AI 使用独立的 Chat Completions 配置，不使用本文的响应外壳或词典只读密钥。

# 错误映射策略（Error Mapping Policy）

所有 fetcher 抛统一 [`QuotaError`](../../Sources/LLM-monitor/Fetchers/QuotaError.swift:4)；
HTTP 错误集中在 [`HTTPClient.send()`](../../Sources/LLM-monitor/Services/HTTPClient.swift:110)，
decoder 错误由各 fetcher 自管。UI 层用
[`userFacingDescription(for:providerKind:)`](../../Sources/LLM-monitor/Fetchers/QuotaError.swift:32)
把 401 翻译成"重新登录"引导文案。

## 错误分类

| Case | 触发场景 |
| --- | --- |
| `.missingAPIKey` | API key 空 / auth 文件无 token |
| `.invalidResponse` | 响应非 `HTTPURLResponse`（本地 RPC） |
| `.httpError(status, body)` | 非 2xx；body 由 `includeBodyInError` 决定 |
| `.decodingError(String)` | JSON / 字段类型 / schema 漂移失败 |
| `.networkError(String)` | `URLError` 翻译后的人类摘要 |

## Per-fetcher 映射

| Fetcher | 鉴权失败 | 业务级错误 |
| --- | --- | --- |
| [Minimax](../../Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift:107) | `base_resp.code==1004` → `httpError(401)` | `code!=0` → `decodingError` |
| [GLM](../../Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift:101) | `code==1000` → `httpError(401)` | `code!=200` → `decodingError` |
| [Codex](../../Sources/LLM-monitor/Fetchers/CodexFetcher.swift:75) | HTTP 401 直出 | HTTP 状态码 → `httpError` |
| [Antigravity](../../Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift:440) | HTTP 401 → `httpError(401)` | `checkHTTP` 2xx 检查 |

minimax / GLM 业务级错误走 HTTP 200 + body `code`（不在 HTTP 层处理）。所有 fetcher
`includeBodyInError: false` —— body 含账号/凭据，错误日志只贴 `"HTTP 503, 1.2KB bytes"`
摘要 [HTTPClient.swift:147](../../Sources/LLM-monitor/Services/HTTPClient.swift:147)。

## Cancellation 过滤

`URLError(code==.cancelled)` 和 `CancellationError` 在
[HTTPClient.swift:127](../../Sources/LLM-monitor/Services/HTTPClient.swift:127) 透传，让
`AppState` 走 `.deferred` 路径不进 failure 计数。AntigravityFetcher
[AntigravityFetcher.swift:425](../../Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift:425)
同样保留 `.cancelled` 重抛。其他 `URLError` 走
[`HTTPRequestLogSanitizer.networkErrorDescription`](../../Sources/LLM-monitor/Services/HTTPClient.swift:28)
映射成中文（"请求超时"、"安全连接失败"），数字错误码不暴露给用户。

## 文案规则

中文优先；401 由 `userFacingDescription` 翻译成 per-provider 操作引导；API key 永不出现，
日志只记录 `key length=N`；路径只保留 `lastPathComponent`；`errorDescription` 自动剥除
`"HTTP N: HTTP N..."` 双重状态码 [QuotaError.swift:18](../../Sources/LLM-monitor/Fetchers/QuotaError.swift:18)。

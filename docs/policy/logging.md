# 日志策略（Logging Policy）

[`AppLog`](../../Sources/LLM-monitor/Services/AppLog.swift:6) 三路：stdout（日志抓取）、日志文件
（`~/Library/Application Support/LLM-monitor/log.txt`）、`os.Logger`
（`subsystem="com.llm-monitor"`）。`logInfo/logWarn/logError/logDebug` 都是 `@autoclosure`，
release 默认不求值。

## 级别 & 最小门禁

| Level | 触发 | 用途 |
| --- | --- | --- |
| `DEBUG` | 仅 DEBUG build | 详细诊断（auth header、JSON 解析路径） |
| `INFO` | 默认 release | 业务事件（parse 成功、轮转、scheduler 调度） |
| `WARN` | 全 build | 异常但可恢复（DB 不可读、缺失字段） |
| `ERROR` | 全 build | 用户可见错误（auth 失败、API 错误） |

[`AppLog.minLevel`](../../Sources/LLM-monitor/Services/AppLog.swift:140) `#if DEBUG` 设 `.debug`、
release 设 `.info`，入口 guard 决定是否求值 `@autoclosure`。格式 `[2026-07-31T12:00:00.123Z] [INFO ] [file:line] msg`；`os.Logger` 三路**全部
`privacy: .private`** [AppLog.swift:212](../../Sources/LLM-monitor/Services/AppLog.swift:212)。

## 文件轮转

单文件 5 MB [`maxLogFileSize`](../../Sources/LLM-monitor/Services/AppLog.swift:19) + 备份 2
份 = `log.txt` + `log.txt.1` + `log.txt.2`。
[`rotateLogFile`](../../Sources/LLM-monitor/Services/AppLog.swift:106) 在专用 `DispatchQueue`
串行 `FileManager.moveItem` 原子 rename；`currentFileSize` queue-owned 避免每条 `stat`。
常规使用 ~7h 触发首次轮转。

## 敏感数据策略

**永不进入日志**：API key 值或前缀（只记录 `key length=N`）、`Authorization` 完整值、URL
`userinfo/query/fragment`、响应 body 全文（`includeBodyInError: false` 默认）。
[`HTTPRequestLogSanitizer.sanitizedURL`](../../Sources/LLM-monitor/Services/HTTPClient.swift:6)
剥除 userinfo/query/fragment；`.networkErrorDescription` [HTTPClient.swift:28](../../Sources/LLM-monitor/Services/HTTPClient.swift:28)
把 `URLError.code` 翻译成稳定中文。**允许进入日志**：HTTP 状态码 + 字节数、解析摘要、
key 长度、文件 `lastPathComponent`、provider id / model name / 错误堆栈、DB fingerprint。

## Per-provider log tag

`[minimax]` [MinimaxTokenPlanFetcher:36](../../Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift:36) ·
`[glm]` [GlmCodingPlanFetcher:43](../../Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift:43) ·
`[codex]` / `[codex/usage]` / `[codex/reset-credits]` [CodexFetcher:51](../../Sources/LLM-monitor/Fetchers/CodexFetcher.swift:51) ·
`[antigravity]` [AntigravityFetcher:419](../../Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift:419) ·
4× `[*-scan]`（各 scanner）。敏感字段在 HTTP 层和各 fetcher 的日志组装入口脱敏。
`ScannerAndLoggingTests` 覆盖 log 0600 权限、
rotate、min-level release/DEBUG 区分、`osLogPrivate` 标签。

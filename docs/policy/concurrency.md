# 并发模型（Concurrency Policy）

Swift 6 strict-concurrency（[`-swift-version 6`](../../scripts/audit.sh:36)）分三类：
`@unchecked Sendable`（调用方契约）、`actor`（runtime 隔离）、`@MainActor`（UI / 状态机）。
决策规则：状态简单 + 调方已串行化 → `@unchecked Sendable`；需 runtime 保护 → `actor`；绑定 UI / `@Published` → `@MainActor`。

## `@unchecked Sendable`

- `HTTPClient` [HTTPClient.swift:79](../../Sources/LLM-monitor/Services/HTTPClient.swift:79) — `URLSession` 自身 thread-safe
- `AppLog` [AppLog.swift:6](../../Sources/LLM-monitor/Services/AppLog.swift:6) — 内部 `DispatchQueue` 串行
- `AppInstanceLock` [AppInstanceLock.swift:6](../../Sources/LLM-monitor/Services/AppInstanceLock.swift:6) — `flock(fd)` 内核锁
- `FileManagerBox` [FileManagerBox.swift:38](../../Sources/LLM-monitor/Services/FileManagerBox.swift:38) — `private fileManager` + 调方 `AsyncMutex`/`@MainActor`
- 4× `NSLock` 容器 — [Formatters:5](../../Sources/LLM-monitor/Services/Formatters.swift:5) / [DateParser:17](../../Sources/LLM-monitor/Services/DateParser.swift:17) / [BrandLogoView:8](../../Sources/LLM-monitor/Views/BrandLogoView.swift:8) / [ProcessRunner:27](../../Sources/LLM-monitor/Services/ProcessRunner.swift:27)
- `ObserverStore` [MenuWindowAutoCloseBridge.swift:24](../../Sources/LLM-monitor/Views/MenuWindowAutoCloseBridge.swift:24) — Coordinator 主线程访问
- 4× scanner — [Minimax:48](../../Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift:48) / [Antigravity:27](../../Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift:27) / [Opencode:17](../../Sources/LLM-monitor/Services/OpencodeUsageScanner.swift:17) / [GlmZcode:26](../../Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift:26) — `@MainActor` + `AsyncMutex.pipelineMutex`

## `actor` 清册

- `AsyncMutex` [AsyncMutex.swift:55](../../Sources/LLM-monitor/Services/AsyncMutex.swift:55) — FIFO `CheckedContinuation` 队列，跨 await 持锁，cancellation-aware
- `CodexUsageDetailsCache` [CodexLocalUsageScanner.swift:4](../../Sources/LLM-monitor/Fetchers/CodexLocalUsageScanner.swift:4) — cache 读写串行

`NSLock` 跨 await 在 Swift 6 mode 报 `unlock() is unavailable`；`AsyncMutex` 替代后整
pipeline（load → RPC → SQL → save）安全持锁。`acquire()` 注册
`withTaskCancellationHandler`，cancel handler 投回 actor 保证只 resume 一次。

## `nonisolated(unsafe)` 清册

测试专用（`#if DEBUG` 隔离，release 编译期消除）：Minimax/Antigravity scanner 的
`testGate` / `testSaveIndexHook` [Minimax:104,106](../../Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift:104) /
[Antigravity:102,104](../../Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift:102)，
`AuthProber.testAfterCancellationCheck` [AuthProber.swift:50](../../Sources/LLM-monitor/Services/AuthProber.swift:50) — 精确
控制 SQL/RPC/apply 之间 cancel 时序。
`MenuBarRightClickHandler.eventMonitor` [MenuBarRightClickHandler.swift:14](../../Sources/LLM-monitor/Services/MenuBarRightClickHandler.swift:14)
是 `Any?` handle，同 actor 路径读写，`deinit` 同步清理（Swift 6 mode 下 `Any` 非 Sendable）。

## `@MainActor` & Cancellation 模式

`ConfigStore` [ConfigStore.swift:155](../../Sources/LLM-monitor/Services/ConfigStore.swift:155) ·
`ProviderRefreshScheduler` [ProviderRefreshScheduler.swift:27](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:27) ·
`AuthProber` [AuthProber.swift:28](../../Sources/LLM-monitor/Services/AuthProber.swift:28) · 4 scanner。模板同构：
`@MainActor` + `nonisolated static performScanPure` + `AsyncMutex.pipelineMutex` 串行。
[`ProviderRefreshScheduler.waitUntilNotInFlight`](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:145)
和 [`AsyncMutex.acquire`](../../Sources/LLM-monitor/Services/AsyncMutex.swift:97) 是 cancellation
范式：guard + `withCheckedThrowingContinuation` + `withTaskCancellationHandler`，cancel
handler 投回 actor 精确移除 waiter；release 与 cancel 通过 actor 串行化防止 continuation
double-resume。

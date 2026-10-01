# 并发模型（Concurrency Policy）

Swift 6 strict-concurrency（[`-swift-version 6`](../../scripts/audit.sh:55)）分三类：
`@unchecked Sendable`（调用方契约）、`actor`（runtime 隔离）、`@MainActor`（UI / 状态机）。
决策规则：状态简单 + 调方已串行化 → `@unchecked Sendable`；需 runtime 保护 → `actor`；绑定 UI / `@Published` → `@MainActor`。

## `@unchecked Sendable`

- `HTTPClient` [HTTPClient.swift:173](../../Sources/LLM-monitor/Services/HTTPClient.swift:173) — `URLSession` 自身 thread-safe
- `AppLog` [AppLog.swift:6](../../Sources/LLM-monitor/Services/AppLog.swift:6) — 内部 `DispatchQueue` 串行
- `AppInstanceLock` [AppInstanceLock.swift:6](../../Sources/LLM-monitor/Services/AppInstanceLock.swift:6) — `flock(fd)` 内核锁
- `FileManagerBox` [FileManagerBox.swift:35](../../Sources/LLM-monitor/Services/FileManagerBox.swift:35) — `private fileManager` + 调方 `AsyncMutex`/`@MainActor`
- 4× `NSLock` 容器 — [Formatters:6](../../Sources/LLM-monitor/Services/Formatters.swift:6) / [DateParser:18](../../Sources/LLM-monitor/Services/DateParser.swift:18) / [BrandLogoView:33](../../Sources/LLM-monitor/Views/BrandLogoView.swift:47) / [ProcessRunner:28](../../Sources/LLM-monitor/Services/ProcessRunner.swift:28)
- `ObserverStore` [MenuWindowAutoCloseBridge.swift:105](../../Sources/LLM-monitor/Views/MenuWindowAutoCloseBridge.swift:105) — Coordinator 主线程访问
- 5× scanner — [Minimax:48](../../Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift:48) / [Antigravity:29](../../Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift:29) / [Opencode:11](../../Sources/LLM-monitor/Services/OpencodeUsageScanner.swift:11) / [GlmZcode:22](../../Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift:22) / [DSH:49](../../Sources/LLM-monitor/Services/DshLocalUsageScanner.swift:49) — `@MainActor` + `AsyncMutex.pipelineMutex`

## `actor` 清册

- `AsyncMutex` [AsyncMutex.swift:55](../../Sources/LLM-monitor/Services/AsyncMutex.swift:55) — FIFO `CheckedContinuation` 队列，跨 await 持锁，cancellation-aware
- `CodexUsageDetailsCache` [CodexLocalUsageScanner.swift:4](../../Sources/LLM-monitor/Services/CodexLocalUsageScanner.swift:4) — cache 读写串行

`NSLock` 跨 await 在 Swift 6 mode 报 `unlock() is unavailable`；`AsyncMutex` 替代后整
pipeline（load → RPC → SQL → save）安全持锁。`acquire()` 注册
`withTaskCancellationHandler`，cancel handler 投回 actor 保证只 resume 一次。

## `nonisolated(unsafe)` 清册

测试专用（`#if DEBUG` 隔离，release 编译期消除）：Minimax/Antigravity scanner 的
`testGate` / `testSaveIndexHook` [Minimax:95,99](../../Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift:95) /
[Antigravity:94,98](../../Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift:94)，
`AuthProber.testAfterCancellationCheck` [AuthProber.swift:50](../../Sources/LLM-monitor/Services/AuthProber.swift:50) — 精确
控制 SQL/RPC/apply 之间 cancel 时序。
`MenuBarRightClickHandler.eventMonitor` [MenuBarRightClickHandler.swift:14](../../Sources/LLM-monitor/Services/MenuBarRightClickHandler.swift:14)
是 `Any?` handle，同 actor 路径读写，`deinit` 同步清理（Swift 6 mode 下 `Any` 非 Sendable）。

## `@MainActor` & Cancellation 模式

`ConfigStore` [ConfigStore.swift:554](../../Sources/LLM-monitor/Services/ConfigStore.swift:554) ·
`ProviderRefreshScheduler` [ProviderRefreshScheduler.swift:26](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:26) ·
`AuthProber` [AuthProber.swift:28](../../Sources/LLM-monitor/Services/AuthProber.swift:28) · 5 scanner。模板同构：
`@MainActor` + `nonisolated static performScanPure` + `AsyncMutex.pipelineMutex` 串行。
[`ProviderRefreshScheduler`](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:26)
用单一可中断 deadline driver 同时服务 regular 与 reset+delay 截止时间；到期网络
batch 独立投递，driver 不在网络请求期间阻塞。
[`ProviderRefreshScheduler.waitUntilNotInFlight`](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:742)
和 [`AsyncMutex.acquire`](../../Sources/LLM-monitor/Services/AsyncMutex.swift:97) 是 cancellation
范式：guard + `withCheckedThrowingContinuation` + `withTaskCancellationHandler`，cancel
handler 投回 actor 精确移除 waiter；release 与 cancel 通过 actor 串行化防止 continuation
double-resume。

## 后台探针的 `@Sendable` 契约

[`SleepHealthService`](../../Sources/LLM-monitor/Services/SleepHealthService.swift:35) 的
「取快照后交给后台线程」写法有两个必须同时满足的条件：

- 注入的时钟/探针闭包（`now` / `assertionProbe` / `powerConfigProbe`）要声明成
  `@Sendable`。它们被捕获进 `Task.detached` 这一非隔离任务，Swift 6 语言模式下非
  Sendable 捕获直接报 `sending` 数据竞争编译错误。
- 三个系统探针（`defaultAssertionProbe` / `defaultPowerConfigProbe` /
  `defaultPmsetCustomRead`）要标 `nonisolated`。类上是 `@MainActor`，函数引用赋给
  闭包变量时隔离会被静默抹掉——编译照过，实际却在后台线程执行，没有任何隔离检查兜底。

`Task.detached` 内部只读这些闭包的返回值，`report` 的发布仍走
`await MainActor.run` + `refreshGeneration` 代际校验（期间有更新的刷新就丢弃旧结果）。

## 编译器坑：`addTask` 闭包上的 `@MainActor` + 捕获列表

`group.addTask { @MainActor [self, providerID] in … }` 这种写法在 Swift 6.4 上会让
region isolation 检查器报 `pattern that the region-based isolation checker does not
understand how to check. Please file a bug`，并**中断整段检查**——同一批次里更早的
真实错误会被它吞掉，表现为"修完 A 冒出 B"。

[`AppState.refreshAll`](../../Sources/LLM-monitor/Services/AppState.swift:428) 与
`handleSystemWake` 因此不写 `@MainActor` 闭包属性，靠 `await self.…` 跨 actor 调用点
保证隔离。改回 `@MainActor` 属性前先确认工具链是否已修这个 bug。


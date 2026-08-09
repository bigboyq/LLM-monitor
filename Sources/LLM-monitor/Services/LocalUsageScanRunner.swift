import Foundation

/// 本地用量 scanner 共享的"扫描生命周期"helper —— 抽取 antigravity / minimax 两个
/// scanner 镜像的 4 段 boilerplate：
///
/// 1. `startedAt` + `defer` 块打印耗时摘要
/// 2. 启动时 `startedGeneration == latestGeneration` 守门（防止旧 worker 启动）
/// 3. 完成时 generation 守门（防止旧 worker 写回新状态）
/// 4. `CancellationFilter.shouldIgnore` 过滤（取消请求不污染 lastError）
///
/// 不负责（留在 scanner 各自实现）：
/// - `@Published lastResult` / `isScanning` / `lastError` 的实际赋值
///   —— 通过 `applyResult` / `applyError` 闭包注入
/// - `AsyncMutex` pipeline 串行化（每个 scanner 有自己的 mutex）
/// - `lastCommittedGeneration` 守门（mutex 内部读 + 写盘 + 更新本实例的 dance）
/// - defer 块里"清 isScanning / inFlightTask"（要 `startedGeneration == latest`
///   才清）—— scanner 自己的 defer 块更直接，不需要 runner 包
///
/// 用法：
/// ```swift
/// func runScan(startedGeneration: UInt64) async {
///     await LocalUsageScanRunner.run(
///         logTag: "[minimax-scan]",
///         startedGeneration: startedGeneration,
///         latestGeneration: { self.latestGeneration },
///         work: { try await Self.performScanPure(...) },
///         applyResult: { result in self.lastResult = result },
///         applyError: { msg in self.lastError = msg }
///     )
/// }
/// ```
///
/// 保留各 scanner 自己的 mutex / cache / 静态 helper 与
/// `performScanPure` 测试表面，只把生命周期 boilerplate
/// 抽出来。完整 base-class 重构需要重写测试，留给后续大版本。
enum LocalUsageScanRunner {
    /// 跑一次 scanner 生命周期。
    ///
    /// - Parameters:
    ///   - logTag: 日志前缀，例如 `[minimax-scan]`
    ///   - startedGeneration: caller 分配的 generation token（`scan()` 入口自增）
    ///   - latestGeneration: 闭包形式拿当前 latest（避免捕获 stale 引用）
    ///   - work: 实际工作（继承 caller 的取消状态，可在内部走 `AsyncMutex`）
    ///   - applyResult: work 成功后把结果写到 scanner 的 `@Published` 字段
    ///   - applyError: work 失败且不是取消时把 error 摘要写到 `lastError`
    static func run<Usage>(
        logTag: String,
        startedGeneration: UInt64,
        latestGeneration: @escaping @MainActor () -> UInt64,
        work: @escaping @Sendable () async throws -> Usage,
        applyResult: @escaping @MainActor (Usage) -> Void,
        applyError: @escaping @MainActor (String) -> Void
    ) async {
        let startedAt = Date()
        logInfo("\(logTag) start (gen=\(startedGeneration))")
        defer {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logInfo("\(logTag) done in \(elapsedMs)ms")
        }
        // 启动时 generation 跟 latest 比对 — 不一致说明已经被 cancel + 新一轮,
        // 当前 runScan 直接放弃（不写 lastResult / 不写 lastError）。
        let initialLatest = await MainActor.run { latestGeneration() }
        guard startedGeneration == initialLatest else {
            logInfo("\(logTag) 启动时 generation 已变 (\(startedGeneration) → \(initialLatest)), 放弃")
            return
        }
        do {
            let result = try await work()
            // 完成时再 generation 比对 —— 中间可能被 cancel + 新 scan 抢了 generation
            let finalLatest = await MainActor.run { latestGeneration() }
            guard startedGeneration == finalLatest else {
                logInfo("\(logTag) 完成时 generation 已变 (\(startedGeneration) → \(finalLatest)), 丢弃结果")
                return
            }
            await MainActor.run { applyResult(result) }
        } catch {
            // 跟 AppState 一样: 取消请求不污染 lastError.
            // 统一 filter 在 `CancellationFilter`, 跟 AppState / Antigravity scanner 共用.
            if CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled) {
                logDebug("\(logTag) 任务被取消 (gen=\(startedGeneration)), 不写 lastError")
                return
            }
            // 错误也走 generation 守门（防止 cancel 后错误也写回）
            let finalLatest = await MainActor.run { latestGeneration() }
            guard startedGeneration == finalLatest else {
                logInfo("\(logTag) 出错时 generation 已变 (\(startedGeneration) → \(finalLatest)), 丢弃错误")
                return
            }
            let message = error.localizedDescription
            logError("\(logTag) failed: \(message)")
            await MainActor.run { applyError(message) }
        }
    }
}

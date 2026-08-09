import Foundation

/// 统一的"是否取消错误"判断。三个调用方共用：
/// - `AppState.refreshProviderDirectly` catch（refresh 路径，federated by HTTPClient）
/// - `MinimaxLocalUsageScanner.runScan` catch（SQLite 扫描）
/// - `AntigravityLocalUsageScanner.runScan` catch（SQLite + 跨源 join）
///
/// 取消来源三种：
/// 1. `Task.isCancelled` —— 当前 Task 被 cancel（父任务 / structured concurrency）
/// 2. `CancellationError` thrown —— fetcher 自己抛的取消
///    （HTTPClient 透传 Swift Concurrency `CancellationError`，不是 `URLError`）
/// 3. `URLError.cancelled` —— URLSession 偶尔直接抛的取消
///
/// 抽出来便于：
/// - 三处统一语义（之前三处 if 表达式字面量一致但分散维护）
/// - 单元测试 filter 本身（不依赖实际 scanner 抛错时序）
enum CancellationFilter {
    /// 检查 error 是不是取消相关（不含 `Task.isCancelled`，那要调方传 `Task.isCancelled`，
    /// 因为 helper 里直接调 `Task.isCancelled` 会捕获 helper 所在的 Task，跟调方的
    /// 实际 task 不一定是同一个——Swift Concurrency 的 `Task` 是 context-sensitive 的）。
    static func isCancellationError(_ error: Error) -> Bool {
        return error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    /// 综合判断：error 是取消错误 OR 当前 Task 已被 cancel。
    /// - `isTaskCancelled`: 调方传 `Task.isCancelled`（捕获调方所在的 task）
    static func shouldIgnore(_ error: Error, isTaskCancelled: Bool) -> Bool {
        return isTaskCancelled || isCancellationError(error)
    }
}

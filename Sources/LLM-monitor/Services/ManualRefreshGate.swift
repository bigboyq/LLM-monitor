import Foundation

/// 显式（手动）full refresh 与正在进行的 background refresh 的合并协议。
///
/// 显式刷新不能被正在进行的 background refresh 吞掉：请求到达时若同 provider
/// 的 background 请求仍在飞行，先登记 pending 标记并等待其结束，结束后只补跑
/// 一次 full refresh（多个等待者只有一个真正补跑）。
///
/// 从 AppState 拆出（原先是一个 Set + 一个计数 dict + 2 个方法散在刷新路径里）：
/// - `registerPending(providerID:)`：等待前登记，refcount 记录"还有几个调用在挂"
/// - `withdrawPending(providerID:)`：等待被取消时撤销本次登记；refcount 归零时
///   连带清掉 pending 标记（R18：泄漏会让下一轮 background 误触发第二次 full）
/// - `claimPendingFullRefresh(providerID:)`：background 结束后的单次 claim，
///   多个等待者只有第一个拿到 true
@MainActor
final class ManualRefreshGate {
    private var pendingFullRefreshIDs: Set<String> = []
    /// 仍在等待同一 background 请求的 full refresh 调用数。用于取消时只撤销
    /// 当前调用的 pending 标记，不影响其他仍在等待的调用。
    private var waiterCounts: [String: Int] = [:]

    /// background 仍在飞行时登记一次 full refresh 请求。
    func registerPending(_ providerID: String) {
        pendingFullRefreshIDs.insert(providerID)
        waiterCounts[providerID, default: 0] += 1
    }

    /// 撤销一个在 background 上挂起的 full refresh 请求（等待被取消时调用）。
    func withdrawPending(_ providerID: String) {
        let remaining = (waiterCounts[providerID] ?? 1) - 1
        if remaining > 0 {
            waiterCounts[providerID] = remaining
        } else {
            waiterCounts.removeValue(forKey: providerID)
            pendingFullRefreshIDs.remove(providerID)
        }
    }

    /// background 结束后 claim 补跑名额；只有第一个等待者拿到 true。
    func claimPendingFullRefresh(_ providerID: String) -> Bool {
        guard pendingFullRefreshIDs.remove(providerID) != nil else { return false }
        waiterCounts.removeValue(forKey: providerID)
        return true
    }

    /// 生命周期停止时清空（ AppState.stop() ）。
    func reset() {
        pendingFullRefreshIDs.removeAll()
        waiterCounts.removeAll()
    }
}

import XCTest
@testable import LLM_monitor

/// `ManualRefreshGate` 的引用计数与单次 claim 协议。对应 `ManualRefreshGate.swift`。
///
/// 这个 gate 决定的是"显式 full 刷新会不会被正在飞的 background 吞掉"，它的两个
/// 不变量此前没有任何测试守着：
/// 1. **恰好补跑一次** —— 多个等待者里只有第一个 claim 成功；
/// 2. **最后一个等待者撤销后不留残留** —— R18：pending 标记泄漏会让下一轮
///    background 误触发第二次 full，表现为"取消了一次手动刷新，几十秒后它自己又刷了一遍"。
final class ManualRefreshGateTests: XCTestCase {

    @MainActor
    func testRegisterThenClaimSucceedsExactlyOnce() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")

        XCTAssertTrue(gate.claimPendingFullRefresh("codex"), "第一个等待者应拿到补跑名额")
        XCTAssertFalse(gate.claimPendingFullRefresh("codex"), "名额只能被领走一次")
    }

    @MainActor
    func testClaimWithoutRegisterReturnsFalse() {
        let gate = ManualRefreshGate()
        XCTAssertFalse(gate.claimPendingFullRefresh("codex"), "没有登记过就没有可领的名额")
    }

    /// 三个等待者 → 只有一次补跑。refcount 存在就是为了这条：pending 是一个 Set，
    /// 如果只看 Set 里的元素个数，多等待者会被当成多次触发。
    @MainActor
    func testMultipleWaitersProduceASingleFullRefresh() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("codex")
        gate.registerPending("codex")

        var claims = 0
        for _ in 0..<3 where gate.claimPendingFullRefresh("codex") {
            claims += 1
        }
        XCTAssertEqual(claims, 1, "三个等待者里只应有一个真正补跑 full")
    }

    /// 撤一个等待者不得连带撤掉别人的：还剩人等时 pending 必须留着。
    @MainActor
    func testWithdrawKeepsPendingWhileAnotherWaiterRemains() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("codex")

        gate.withdrawPending("codex")

        XCTAssertTrue(
            gate.claimPendingFullRefresh("codex"),
            "还有一个等待者挂在 background 上时，pending 不得被撤销"
        )
    }

    /// R18 回归：refcount 归零时必须把 pending 一起清掉。漏掉这一步，
    /// 被取消的手动刷新会在下一轮 background 结束后被"补跑"出来。
    @MainActor
    func testWithdrawToZeroClearsPending() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("codex")

        gate.withdrawPending("codex")
        gate.withdrawPending("codex")

        XCTAssertFalse(
            gate.claimPendingFullRefresh("codex"),
            "最后一个等待者撤销后必须清掉 pending，否则会多补跑一次 full"
        )
    }

    /// provider 之间互不干扰：一个 provider 的撤销不得吃掉另一个的 pending。
    @MainActor
    func testProvidersAreIsolatedFromEachOther() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("antigravity")

        gate.withdrawPending("codex")

        XCTAssertFalse(gate.claimPendingFullRefresh("codex"), "codex 已全部撤销")
        XCTAssertTrue(gate.claimPendingFullRefresh("antigravity"), "antigravity 的 pending 不该被 codex 的撤销带走")
    }

    /// 从未登记过就 withdraw：不得凭空影响任何人（`waiterCounts[id] ?? 1` 那个
    /// 兜底 1 意味着"只撤自己这一次"）。
    @MainActor
    func testWithdrawWithoutRegisterLeavesOthersAlone() {
        let gate = ManualRefreshGate()
        gate.registerPending("antigravity")

        gate.withdrawPending("codex")

        XCTAssertTrue(
            gate.claimPendingFullRefresh("antigravity"),
            "对未登记的 provider 撤销，不得清掉别人已登记的 pending"
        )
    }

    /// `AppState.stop()` 走的 reset：生命周期结束后不得还有残留 pending。
    @MainActor
    func testResetClearsEveryPendingProvider() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("antigravity")

        gate.reset()

        XCTAssertFalse(gate.claimPendingFullRefresh("codex"))
        XCTAssertFalse(gate.claimPendingFullRefresh("antigravity"))
    }

    /// 完整一轮：登记 → 有人领到名额 → 后续等待者领不到，且 refcount 状态被清干净
    /// （再 register 一次应当能重新领到，说明上次 claim 没有留下脏计数）。
    @MainActor
    func testClaimResetsRefcountSoTheNextRoundCanRegisterAgain() {
        let gate = ManualRefreshGate()
        gate.registerPending("codex")
        gate.registerPending("codex")
        XCTAssertTrue(gate.claimPendingFullRefresh("codex"))
        XCTAssertFalse(gate.claimPendingFullRefresh("codex"))

        gate.registerPending("codex")
        XCTAssertTrue(
            gate.claimPendingFullRefresh("codex"),
            "claim 必须把 waiter 计数清干净，下一轮登记不该被旧 refcount 吞掉"
        )
    }
}

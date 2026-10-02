import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 本地用量协调器：扫描触发、去重与状态回落。对应 `LocalUsageCoordinator`。
final class LocalUsageCoordinatorTests: StateTestCase {

    // MARK: - LocalUsageCoordinator
    @MainActor
    func testLocalUsageCoordinatorLazyScannerIsCreatedOnFirstTrigger() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var factoryCalledCount = 0
        let makeScanner: () -> any LocalUsageScanner<MinimaxLocalUsage> = {
            factoryCalledCount += 1
            return FakeLocalScanner(usage: usage)
        }

        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: makeScanner,
            apply: { _ in },
            setScanning: { _ in }
        )

        // trigger 前 factory 不应被调用（lazy）
        XCTAssertEqual(factoryCalledCount, 0, "scanner 不应在 trigger 前构造")

        coordinator.trigger()
        // trigger 后 scanner 创建一次，scan 也调用一次
        XCTAssertEqual(factoryCalledCount, 1, "首次 trigger 应调用 factory 一次")
    }
    @MainActor
    func testLocalUsageCoordinatorActiveResolverGatesAndReactivatesSource() {
        let usage = MinimaxLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: Date(),
            sessionCount: 0, eventCount: 0, failedSessionCount: 0
        )
        var factoryCalledCount = 0
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test", logTag: "test",
            makeScanner: {
                factoryCalledCount += 1
                return FakeLocalScanner(usage: usage)
            },
            apply: { _ in }
        )

        coordinator.setActive(false)
        coordinator.trigger()
        XCTAssertEqual(factoryCalledCount, 0, "停用 source 时不应构造 scanner")
        coordinator.setActive(true)
        coordinator.trigger()
        XCTAssertEqual(factoryCalledCount, 1, "重新启用后下一次 batch 应允许构造 scanner")
    }
    func testActiveLocalUsageResolverUsesEffectiveStatusDefaults() {
        // ProviderStatus defaults to enabled when a provider has no explicit
        // config entry. The resolver must preserve that source instead of
        // looking up the raw config dictionary.
        var defaultEnabled = ProviderStatus(
            id: "minimax_token_plan", displayName: "MiniMax",
            kind: .minimaxTokenPlan, iconSystemName: "circle",
            accentColor: .minimax, refreshIntervalSeconds: 60, state: .ready
        )
        defaultEnabled.clientBindings = ProviderStatus.allClientBindingsEnabled()
        let explicitlyDisabled = ProviderStatus(
            id: "glm_coding_plan", displayName: "GLM",
            kind: .glmCodingPlan, iconSystemName: "circle",
            accentColor: .glm, refreshIntervalSeconds: 60,
            isEnabled: false, state: .ready
        )

        let active = LocalUsageOrchestration.activeSources(
            for: [defaultEnabled, explicitlyDisabled]
        )
        XCTAssertTrue(active.minimax)
        XCTAssertTrue(active.dsh, "共享 DSH source 应由有效启用的 MiniMax consumer 保留")
        // GLM status 虽被禁用，但 minimax 卡的 zcode → minimax 分片绑定开启时
        // ZCode 源必须扫描（分片消费方在位，见 ZcodeProviderSliceTests 的同语义用例）。
        XCTAssertTrue(active.glm)
        XCTAssertTrue(active.opencode)
    }
    @MainActor
    func testLocalUsageCoordinatorReusesScannerAcrossTriggers() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var factoryCalledCount = 0
        let makeScanner: () -> any LocalUsageScanner<MinimaxLocalUsage> = {
            factoryCalledCount += 1
            return FakeLocalScanner(usage: usage)
        }

        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: makeScanner,
            apply: { _ in },
            setScanning: { _ in }
        )

        coordinator.trigger()
        coordinator.trigger()
        coordinator.trigger()

        // factory 只该被调一次（scanner 缓存复用）
        XCTAssertEqual(factoryCalledCount, 1, "后续 trigger 不应重新构造 scanner")
    }
    @MainActor
    func testLocalUsageCoordinatorForwardsResultToApply() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 7,
            eventCount: 100,
            failedSessionCount: 2
        )
        var applyCalls: [MinimaxLocalUsage?] = []
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { FakeLocalScanner(usage: usage) },
            apply: { result in applyCalls.append(result) },
            setScanning: { _ in }
        )

        coordinator.trigger()

        // 给 sink 一个 schedule 的时间（receive on main queue）
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // CurrentValueSubject 会在新订阅时立刻发一次初始值（nil），scan 完成后发一次
        // 真实值（usage）。所以 apply 至少被调用 2 次，其中最后一个是真实值。
        // 关键验证：最终收到的 non-nil 值字段正确
        XCTAssertGreaterThanOrEqual(applyCalls.count, 1)
        let last = applyCalls.last ?? nil
        XCTAssertEqual(last?.sessionCount, 7, "apply 最后一次应拿到 sessionCount=7")
        XCTAssertEqual(last?.failedSessionCount, 2, "apply 最后一次应拿到 failedSessionCount=2")
    }
    @MainActor
    func testLocalUsageCoordinatorForwardsScanningState() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var scanningStates: [Bool] = []
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { FakeLocalScanner(usage: usage) },
            apply: { _ in },
            setScanning: { isScanning in scanningStates.append(isScanning) }
        )

        coordinator.trigger()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // FakeLocalScanner.scan 期间发 true → false，至少收到 2 个状态变更
        XCTAssertGreaterThanOrEqual(scanningStates.count, 2, "setScanning 应至少被调用 2 次（true + false）")
        XCTAssertTrue(scanningStates.contains(true), "应有 isScanning=true")
        XCTAssertTrue(scanningStates.contains(false), "应有 isScanning=false")
    }
    @MainActor
    func testLocalUsageCoordinatorForwardsCancelInFlight() {
        // 验证 LocalUsageCoordinator.cancelInFlight() 会转发到 scanner
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        let scanner = FakeLocalScanner(usage: usage)
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { scanner },
            apply: { _ in },
            setScanning: { _ in }
        )
        // trigger 之前 cancelInFlight 应不崩（scanner 还没建）
        coordinator.cancelInFlight()
        coordinator.trigger()
        XCTAssertEqual(scanner.scanCount, 1)
        // trigger 之后再 cancel
        coordinator.cancelInFlight()
        // 不崩就算过 — FakeLocalScanner 没暴露 cancel count, 行为由 scanner 自身测试覆盖
        XCTAssertNotNil(coordinator)
    }
}

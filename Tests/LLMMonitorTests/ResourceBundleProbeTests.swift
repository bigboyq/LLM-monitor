import XCTest
import Foundation
@testable import LLM_monitor

/// `ResourceBundleProbe` 守门。
///
/// 存在理由：`Bundle.module` 在**资源 bundle 整体缺失**时自身 `fatalError`，
/// 于是"资源缺失就降级"的分支根本到不了（DMG 拷贝不完整 / 用户删资源 = 无限
/// 崩溃）。本测试覆盖两条路径：探测到 bundle（正常路径行为不变）与探测不到
/// bundle（走降级，不碰 `Bundle.module`）。缺失路径用**注入的无效候选路径**
/// 构造，不真删资源。
final class ResourceBundleProbeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ResourceBundleProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    /// 命中路径：候选位置下存在 `LLM-monitor_LLM-monitor.bundle` 目录 → 可用。
    func testProbeFindsBundleWhenCandidateDirectoryExists() throws {
        let bundleDir = tempDir
            .appendingPathComponent("\(ResourceBundleProbe.resourceBundleName).bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        XCTAssertTrue(
            ResourceBundleProbe.probe(candidates: [bundleDir]),
            "候选位置存在资源 bundle 时必须判定为可用（否则正常安装会被误降级）"
        )
    }

    /// 未命中路径：候选位置没有这个 bundle → 不可用，调用方才有资格走降级分支。
    func testProbeReportsMissingWhenCandidateDirectoryAbsent() {
        let missing = tempDir
            .appendingPathComponent("no-such-root")
            .appendingPathComponent("\(ResourceBundleProbe.resourceBundleName).bundle")

        XCTAssertFalse(
            ResourceBundleProbe.probe(candidates: [missing]),
            "候选位置没有资源 bundle 时必须判定为不可用"
        )
    }

    /// 空候选（连一个候选路径都给不出）与全空候选列表都算不可用——不允许在
    /// "没查清楚"的情况下默认当成可用，那等于没探测。
    func testProbeTreatsEmptyCandidateListAsMissing() {
        XCTAssertFalse(ResourceBundleProbe.probe(candidates: []))
    }

    /// 生产路径：探测口径必须与 SwiftPM 生成的 accessor 一致——本测试进程里
    /// bundle **确实存在**（`ModelPricingJSONTests` 也从同一个 accessor 取到了
    /// ModelPricing.json），因此 `isResourceBundleAvailable` 必须是 true。
    /// 这条同时钉住"探测逻辑没有把正常环境误判成资源缺失"。
    func testProductionProbeAgreesWithRealBundle() {
        XCTAssertFalse(
            ResourceBundleProbe.candidateBundleURLs().isEmpty,
            "候选列表不应为空（至少 Bundle.main.bundleURL 恒在）"
        )
        XCTAssertTrue(
            ResourceBundleProbe.isResourceBundleAvailable,
            "本测试进程内资源 bundle 确实存在（ModelPricing.json 可从 Bundle.module 取到），探测不得误判为缺失"
        )
    }

    /// 正常路径不因探测而改变行为：价格目录必须是真数据，不是降级空目录。
    func testPricingCatalogIsNotDegradedInHealthyEnvironment() {
        XCTAssertTrue(ResourceBundleProbe.isResourceBundleAvailable)
        XCTAssertNotEqual(
            ModelPricingCatalog.lastUpdated,
            "未知（资源缺失）",
            "资源 bundle 可用时价格目录不得走空目录降级"
        )
    }
}

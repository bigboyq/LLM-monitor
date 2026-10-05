import Foundation

/// 资源 bundle 探测 —— `Bundle.module` 访问器的前置门卫。
///
/// **为什么需要它**：`Bundle.module` 是 SwiftPM 为带 resources 的 target 生成的
/// 访问器，它**自己**在找不到 bundle 时 `fatalError`（产物里的字面量是
/// `unable to find bundle named LLM-monitor_LLM-monitor`）。于是任何写在
/// `Bundle.module.url(forResource:)` 之后的降级分支——"资源缺失就退化成空表"、
/// "记一条日志继续跑"——在**bundle 整体缺失**时都根本到不了：DMG 拷贝不完整、
/// 用户删掉了 `LLM-monitor_LLM-monitor.bundle`、权限不足等场景下 App 无限崩溃。
///
/// **怎么用**：消费资源的类型在触碰 `Bundle.module` 之前先问一次本探测。
/// - bundle 整体缺失 → 走各自既有的降级语义（本仓：价格目录降级成空目录 +
///   error 日志；节假日表降级成空表），App 继续可用；
/// - bundle 在、但具体资源缺失或 JSON 损坏 → **不动**，仍由各自的既有策略
///   决定（`ModelPricingCatalog` 的 `preconditionFailure` 是有意的"崩溃暴露"，
///   本 helper 不改变它）。
///
/// **不复制 accessor's 语义**：候选根目录与 SwiftPM 生成的 accessor 保持同序同
/// 形状（DEBUG 下的 `PACKAGE_RESOURCE_BUNDLE_PATH` override → `Bundle.main.resourceURL`
/// → 所在 bundle 的 `resourceURL` → `Bundle.main.bundleURL`），因此"探测说找不到"
/// 与"accessor 会 fatalError"是同一个判定；本 helper 存在的唯一意义是让调用方
/// 有机会在崩溃**之前**走降级分支。
enum ResourceBundleProbe {
    /// SwiftPM 为 `<package>_<target>` 生成的 bundle 名。改动 target 名 / package 名时
    /// 需同步（与生成代码里的 `bundleName` 字面量同一来源）。
    static let resourceBundleName = "LLM-monitor_LLM-monitor"

    /// `Bundle(for:)` 的锚点类。accessor 用的是它自己生成的 `BundleFinder`；
    /// 同一个 module 里的任意类解析到同一个 bundle，因此这里等价。
    private final class BundleAnchor {}

    /// 候选 bundle 根目录，顺序与 SwiftPM 生成的 accessor 一致。
    ///
    /// - Parameter environment: 进程环境，默认 `ProcessInfo.processInfo.environment`。
    ///   显式注入便于测试构造"override 存在 / 不存在"两种布局。
    static func candidateBundleURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL?] = []
        #if DEBUG
        // accessor 在 DEBUG 下优先认这两个 override（首选 PATH，URL 兼容旧写法）。
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            roots.append(URL(fileURLWithPath: override))
        }
        #endif
        roots.append(Bundle.main.resourceURL)
        roots.append(Bundle(for: BundleAnchor.self).resourceURL)
        roots.append(Bundle.main.bundleURL)
        let suffix = "\(resourceBundleName).bundle"
        return roots.compactMap { $0?.appendingPathComponent(suffix) }
    }

    /// 按候选列表探测资源 bundle 是否可用。**不触碰 `Bundle.module`**。
    ///
    /// 判定口径与 accessor 一致：候选路径能被 `Bundle(url:)` 打开即视为可用。
    /// `candidates` 为 nil 时用 `candidateBundleURLs()`；注入候选路径供测试构造
    /// "存在 / 缺失"两条路径（不真删资源）。
    static func probe(
        candidates: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let candidates = candidates ?? candidateBundleURLs(environment: environment)
        return candidates.contains { Bundle(url: $0) != nil }
    }

    /// 生产入口：进程内只探测一次并缓存。资源 bundle 的存在与否在进程生命周期内
    /// 不会变化（不热替换打包资源），因此没有必要反复 stat 磁盘。
    nonisolated static let isResourceBundleAvailable: Bool = probe()
}

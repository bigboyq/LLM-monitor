import Foundation

/// 通知触发器基线的单模型窗口快照（与 `ModelQuota` 的两个窗口对齐）。
struct QuotaWindowBaseline: Codable, Equatable, Sendable {
    var intervalPresent: Bool
    var intervalRemainingPercent: Double
    var weeklyPresent: Bool
    var weeklyRemainingPercent: Double
}

/// 一个 provider 的触发器基线：modelName（lowercased）→ 窗口基线。
/// 只持久化判定所需的最小标量，schema 演化与 `QuotaInfo` 解耦。
struct QuotaSnapshot: Codable, Equatable, Sendable {
    var models: [String: QuotaWindowBaseline]
    var updatedAt: Date

    init(models: [String: QuotaWindowBaseline], updatedAt: Date = Date()) {
        self.models = models
        self.updatedAt = updatedAt
    }

    /// 从一次成功的 `QuotaInfo` 提取基线。key 与 `QuotaEventDetector` 的匹配键
    /// 一致（`modelName.lowercased()`，冲突取 first）。DeepSeek 等非窗口类
    /// provider 的门控在 AppState（`windowedKinds`），本层不做 kind 判断。
    init(from info: QuotaInfo, updatedAt: Date = Date()) {
        var models: [String: QuotaWindowBaseline] = [:]
        for model in info.models {
            guard model.hasIntervalWindow || model.hasWeeklyWindow else { continue }
            let key = model.modelName.lowercased()
            guard models[key] == nil else { continue }
            models[key] = QuotaWindowBaseline(
                intervalPresent: model.hasIntervalWindow,
                intervalRemainingPercent: model.intervalRemainingPercent,
                weeklyPresent: model.hasWeeklyWindow,
                weeklyRemainingPercent: model.weeklyRemainingPercent
            )
        }
        self.init(models: models, updatedAt: updatedAt)
    }
}

/// 触发器基线持久化（`notification-state.json`）。
///
/// 通知检测的 previous 单一来源：相比内存 `statuses.lastSuccess`，基线跨重启
/// 连续 —— app 停机期间发生的耗尽/恢复事件，重启后第一次刷新即可补报，而不是
/// 静默重建基线漏掉。写盘用 `FileManagerBox.writePrivate`
/// （0600 / 临时文件 / fsync / rename 原子替换）；坏文件容错降级为空基线，
/// 不进损坏恢复流程。
///
/// 写入策略（2026-09-14 裁定）：**每次更新同步直写，不做防抖合并**。频率只有
/// 每 provider 每刷新周期一次（refreshAll 突发也就 4 次）、文件 ~2KB，主线程
/// 直写成本可忽略；同步顺序写从构造上消除并发写竞态，比防抖 + 后台写更简单。
@MainActor
final class TriggerStateStore {
    private let fileURL: URL
    private var snapshots: [String: QuotaSnapshot]

    init(configURL: URL) {
        self.fileURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("notification-state.json")
        self.snapshots = Self.load(from: fileURL)
    }

    func snapshot(for providerID: String) -> QuotaSnapshot? {
        snapshots[providerID]
    }

    /// 成功刷新后更新基线并立即落盘。无条件写（与是否配置了触发器无关），
    /// 保证"先开监控、后开触发器"的边沿语义一致。
    func update(providerID: String, info: QuotaInfo) {
        snapshots[providerID] = QuotaSnapshot(from: info)
        Self.write(snapshots, to: fileURL)
    }

    /// provider 进入 `.notConfigured` 时丢弃基线：重新配置后回到
    /// "首帧只建基线不通知"语义，不拿陈旧基线误报。
    func reset(providerID: String) {
        guard snapshots.removeValue(forKey: providerID) != nil else { return }
        Self.write(snapshots, to: fileURL)
    }

    private nonisolated static func write(_ snapshots: [String: QuotaSnapshot], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshots) else {
            logWarn("[trigger-state] 触发器基线序列化失败，跳过写盘")
            return
        }
        do {
            try FileManagerBox().writePrivate(data, to: url)
        } catch {
            logWarn("[trigger-state] 触发器基线写盘失败: \(error.localizedDescription)")
        }
    }

    private nonisolated static func load(from url: URL) -> [String: QuotaSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: QuotaSnapshot].self, from: data)
        } catch {
            logWarn("[trigger-state] 触发器基线文件解析失败，按空基线处理: \(error.localizedDescription)")
            return [:]
        }
    }
}

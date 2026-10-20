import Foundation
import Combine

extension AppState {
    /// 综合所有已启用 Provider 计算的全局系统健康度等级。
    /// - 若没有启用的 provider，返回 nil。
    /// - 若任意启用的 provider 处于失败且无缓存状态或 `.critical`，返回 `.critical`。
    /// - 若任意启用的 provider 处于 `.warning` 或高峰期窗口生效中，返回 `.warning`。
    /// - 否则返回 `.healthy`。
    var systemHealthLevel: HealthLevel? {
        systemHealthLevel(at: Date())
    }

    /// 指定时刻计算系统健康度。状态栏的分钟时钟用它跨越高峰边界，测试也能
    /// 注入固定时间，避免依赖墙上时钟。
    func systemHealthLevel(at now: Date) -> HealthLevel? {
        let enabled = statuses.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        var levels: [HealthLevel] = []

        // DeepSeek is balance-only and intentionally has no quota window
        // semantics; the quotaLogo aggregate below (and the notification
        // pipeline) exclude it accordingly. This aggregate feeds the health
        // dot of the legacy SF Symbol icon style. It reads the same
        // `ProviderStatus.aggregateHealthLevel` as the card header dot
        // (unified colorLevel + 周 × N + GLM peak floor), so the SF Symbol
        // dot and the card dot agree for every provider. DeepSeek's balance
        // health is still counted here (balance ¥0 → .critical): its balance
        // model has only a 5h-shaped window with no reset time, so
        // aggregateHealthLevel colors it by the same colorLevel thresholds the
        // balance reading always went through; the remaining known scope
        // difference is that DeepSeek participates here while being excluded
        // from the quotaLogo aggregate.
        for status in enabled {
            switch status.state {
            case .failed(message: _, lastSuccess: nil):
                // 无缓存的失败仍是最严重档；aggregateHealthLevel 对
                // lastSuccess == nil 返回 nil，需单独保留该语义。
                return .critical
            case .ok, .loading(lastSuccess: .some), .failed(message: _, lastSuccess: .some):
                // 与卡片同一口径：卡片标题行的状态由 `ProviderStateLabel` 胶囊说出，
                // 这里的聚合档位要与之同源。
                if let level = status.aggregateHealthLevel(at: now) {
                    levels.append(level)
                }
            case .notConfigured, .ready, .loading(lastSuccess: nil):
                break
            }

            if status.isGlmPeak(at: now) {
                levels.append(.warning)
            }
            if let deepseekPeak = status.deepseekPeakWindow, case .peak = deepseekPeak.status(at: now) {
                levels.append(.warning)
            }
        }

        guard !levels.isEmpty else { return nil }
        return levels.min()
    }

    /// 计算当前状态栏配额指标：左弧 5h、右弧周额度、中间为所有有效套餐
    /// 「实际可用」比例（min(5h, 周 × N)）的最低值，底部三点按统一 colorLevel
    /// 判定（实际可用口径 + 高峰 floor）红 > 黄 > 绿排列。聚合 model 集合已排除
    /// minimax video / antigravity Claude and GPT 组（`QuotaInfo.aggregateQuotaModels`）。
    func statusBarQuotaMetrics(at now: Date = Date()) -> StatusBarQuotaMetrics {
        let enabled = statuses.filter(\.isEnabled)
        // (kind, model, isPeak) 三元组：中心扇形与底部三点的「实际可用」口径需要
        // provider 的周等效倍率 N（与卡片分段条 min(5h, 周 × N) 同源），高峰 floor
        // 也按 provider 维度取 kind 对应的高峰状态，收集时顺带记录。deepseek 已被
        // 下面过滤器排除（其 deepseekPeakWindow 无需处理）；其他 kind 的
        // glmPeakWindow 为 nil，自然不算高峰。
        var activeWindowedModels: [(kind: ProviderKind, model: ModelQuota, isPeak: Bool)] = []
        // DeepSeek is balance-only and intentionally has no quota window
        // semantics; it is excluded from the quotaLogo aggregate just as the
        // notification pipeline excludes non-windowed providers.
        for status in enabled where status.kind != .deepseek {
            // 高峰判定跟随 systemHealthLevel 现状：isGlmPeak 命中 .peak 即 true。
            let isPeak = status.isGlmPeak(at: now)
            switch status.state {
            case .ok(let info), .loading(lastSuccess: let info?), .failed(message: _, lastSuccess: let info?):
                activeWindowedModels.append(contentsOf: info.aggregateQuotaModels(providerKind: status.kind).map { (kind: status.kind, model: $0, isPeak: isPeak) })
            case .notConfigured, .ready, .loading(lastSuccess: nil), .failed(message: _, lastSuccess: nil):
                break
            }
        }
        let allActiveModels = activeWindowedModels.map(\.model)

        // 1. 5h 窗口 (原始值，不带时间系数)
        let intervalMetrics = ringMetrics(allActiveModels.filter(\.hasIntervalWindow)) {
            $0.intervalRemainingPercent
        }

        // 2. 周窗口 (原始百分比，不带时间系数)
        let weeklyMetrics = ringMetrics(allActiveModels.filter(\.hasWeeklyWindow)) {
            $0.weeklyRemainingPercent
        }

        // 3. 中心扇形 = 仍有剩余的套餐中「实际可用」比例的最低值，与卡片分段条
        // 的 min(5h, 周 × N) 口径一致：每个套餐按自身存在的窗口取
        // min(5h 剩余, 周剩余 × 周等效倍率 N)——仅 5h 按 5h 参与、仅周按 周 × N
        // 参与，单套餐结果 clamp 到 [0, 1]。多套餐接力场景下，已耗尽（实际可用
        // 为 0）的套餐不参与取 min，中心跟随仍在服役的接力套餐的剩余量；全部
        // 套餐耗尽时回退 0（红），所有套餐都没有任何窗口时保持 nil（灰）。
        // 顺带记录产生最小值的套餐（argmin，并列保留先出现者）及其瓶颈窗口的
        // 剩余时间比例，作为中心扇形 colorLevel 的动态黄线输入——0 值套餐被
        // 排除导致胜出套餐变化时，timeFraction 一并跟随新胜出者。左右弧仍分别
        // 表达两种窗口的原始物理剩余；底部三点按统一 colorLevel 判定（实际可用
        // 口径 + 高峰 floor），不排除耗尽套餐（用完的套餐点保持红），构造器
        // 负责排序、截断到三个并用默认绿色补齐。
        var centerBest: (value: Double, bindingTimeFraction: Double?)?
        var hasAnyReading = false
        for entry in activeWindowedModels {
            guard let reading = entry.model.aggregateActualAvailable(providerKind: entry.kind, at: now) else { continue }
            hasAnyReading = true
            let value = reading.percent / 100.0
            // 接力：耗尽（实际可用为 0）的套餐不参与中心 min；底部三点仍计入。
            guard value > 0 else { continue }
            if centerBest == nil || value < centerBest!.value {
                centerBest = (value, reading.bindingTimeFraction)
            }
        }
        let centerAvailable: Double?
        let centerTimeFraction: Double?
        if let best = centerBest {
            centerAvailable = best.value
            centerTimeFraction = best.bindingTimeFraction
        } else {
            // 有读数但全部耗尽 → 0（红色空心环）；无任何读数 → nil（未配置灰）。
            centerAvailable = hasAnyReading ? 0.0 : nil
            centerTimeFraction = nil
        }
        let quotaHealthLevels = activeWindowedModels.map {
            $0.model.aggregateHealthLevel(providerKind: $0.kind, isPeakPrice: $0.isPeak)
        }
        // 聚合右弧的动态黄线输入：所有周窗口套餐剩余时间比例的最大值。
        let weeklyTimeFraction = allActiveModels
            .compactMap { $0.weeklyTimeRemainingFraction(at: now) }
            .max()
        // 聚合左弧的动态黄线输入同理：所有长 interval 窗口剩余时间比例的最大值。
        let intervalTimeFraction = allActiveModels
            .compactMap { $0.intervalTimeRemainingFraction(at: now) }
            .max()

        return StatusBarQuotaMetrics(
            weekly: weeklyMetrics,
            interval: intervalMetrics,
            centerAvailable: centerAvailable,
            quotaHealthLevels: quotaHealthLevels,
            weeklyTimeFraction: weeklyTimeFraction,
            centerTimeFraction: centerTimeFraction,
            intervalTimeFraction: intervalTimeFraction
        )
    }

    /// 单侧聚合弧的读数：所有含该窗口 model 的原始剩余比例取 min/avg；空集 = 无该窗口。
    private func ringMetrics(
        _ models: [ModelQuota],
        percent: (ModelQuota) -> Double
    ) -> QuotaRingMetrics {
        guard !models.isEmpty else {
            return QuotaRingMetrics(minAvailable: 0.0, avgAvailable: 0.0, isAvailable: false)
        }
        let pcts = models.map { min(max(percent($0) / 100.0, 0.0), 1.0) }
        return QuotaRingMetrics(
            minAvailable: pcts.min() ?? 1.0,
            avgAvailable: pcts.reduce(0.0, +) / Double(pcts.count)
        )
    }
}

import SwiftUI

/// 图表使用的单日规范化值。
///
/// Provider 数据通常已经在扫描层归一化，但 view 仍可能收到损坏的缓存值或测试构造值。
/// 在这里再次收口，避免负数柱高、格式化负 token，或 `Int` 求和溢出。
struct LocalUsageChartDayMetrics: Equatable {
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let cacheTotal: Int
    let inputTotal: Int
    let outputTotal: Int

    /// 用于绘图的输出分量。正常值与原 token 数相同；当 `output + reasoning`
    /// 超出 `Int.max` 时按比例压缩到饱和总量，确保堆叠柱不超过其总高度。
    let outputChartValue: Double
    let reasoningChartValue: Double

    init<Daily: LocalUsageDaily>(_ day: Daily) {
        let safeInput = SaturatingArithmetic.add(day.input, 0)
        let safeCacheRead = SaturatingArithmetic.add(day.cacheRead, 0)
        let safeCacheWrite = SaturatingArithmetic.add(day.cacheWrite, 0)
        let safeOutput = SaturatingArithmetic.add(day.output, 0)
        let safeReasoning = SaturatingArithmetic.add(day.reasoning, 0)
        let safeOutputTotal = day.outputTotal

        input = safeInput
        cacheRead = safeCacheRead
        cacheWrite = safeCacheWrite
        output = safeOutput
        reasoning = safeReasoning
        // cacheWrite remains available in the raw daily object for diagnostics,
        // but is intentionally excluded from the estimate/chart layer.
        cacheTotal = safeCacheRead
        inputTotal = day.inputTotal
        outputTotal = safeOutputTotal

        let rawOutput = Double(safeOutput)
        let rawReasoning = Double(safeReasoning)
        let rawTotal = rawOutput + rawReasoning
        let representedTotal = Double(safeOutputTotal)
        let scale = rawTotal > representedTotal && rawTotal > 0
            ? representedTotal / rawTotal
            : 1
        outputChartValue = rawOutput * scale
        reasoningChartValue = rawReasoning * scale
    }
}

/// 一次遍历计算图表的三个缩放基准，避免 SwiftUI body 中为每种 token 重复扫描数组。
struct LocalUsageChartScale: Equatable {
    let maxUncached: Double
    let maxCachedWeight: Double
    let maxOutputWeight: Double

    init<Daily: LocalUsageDaily>(days: [Daily]) {
        var maxInput = 0
        var maxCacheWeight = 0.0
        var maxOutput = 0

        for day in days {
            let metrics = LocalUsageChartDayMetrics(day)
            maxInput = max(maxInput, metrics.input)
            maxCacheWeight = max(maxCacheWeight, TokenChartScale.weight(for: metrics.cacheTotal))
            // 必须比较每一天的 output + reasoning；分别取最大值后相加会把不同日期
            // 的峰值错误地组合起来，导致所有输出柱被压矮。
            maxOutput = max(maxOutput, metrics.outputTotal)
        }

        maxUncached = Double(max(maxInput, 1))
        maxCachedWeight = max(maxCacheWeight, 1)
        maxOutputWeight = Double(max(maxOutput, 1))
    }
}

/// 7-day token 用量 hover 图表（泛型）—— 4 类 provider 数据共用。
///
/// 取代了原来 3 个几乎一样的 view，并接入 OpenCode daily 数据：
/// - `AntigravitySevenDayHoverView` (ProviderCardView line 1937-2050)
/// - `SevenDayTokenUsageHoverView` (codex, line 1036-1185)
/// - `MinimaxSevenDayHoverView` (我刚加的)
///
/// 视觉完全等价：相同的 4 色（input 蓝 / cache 青 / output 绿 / reason 橙）、
/// 相同的柱高算法（25.6 input + 38.4 cache + 64.0 output）、
/// 相同的 R/T 表格 + 相同的 390pt 宽度限制。
///
/// 字段访问通过 `LocalUsageDaily` 协议统一（见 `Models/LocalUsageDaily.swift`）：
/// antigravity / codex / minimax 各自 computed property adapter。
struct SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>: View {
    let days: [Daily]
    let scannedAt: Date?
    let isScanning: Bool
    /// Optional per-day cost text. Client settings passes this so the table
    /// reads `Reason → 价值`; provider cards keep the historical 6-column view.
    ///
    /// `@autoclosure`：`HoverInfoRow` 在 init 时就会求值 detail 闭包，若这里直接
    /// 收 `[Date: String]`，卡片 footer 的每次 body 重算都会白跑一遍
    /// `ModelPricingCatalog` 定价估算——即使 hover 图从未打开。收闭包并只在
    /// 本 view 的 body 内调用，定价计算才真正惰性化。
    private let priceByDayProvider: () -> [Date: String]

    init(
        days: [Daily],
        scannedAt: Date?,
        isScanning: Bool,
        priceByDay: @autoclosure @escaping () -> [Date: String] = [:]
    ) {
        self.days = days
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.priceByDayProvider = priceByDay
    }

    private let inputColor = Color(red: 0.16, green: 0.47, blue: 0.91)
    private let cacheColor = Color(red: 0.18, green: 0.70, blue: 0.76)
    private let outputColor = Color(red: 0.11, green: 0.64, blue: 0.34)
    private let reasonColor = Color(red: 0.90, green: 0.46, blue: 0.16)

    var body: some View {
        let chartScale = LocalUsageChartScale(days: days)
        let priceByDay = priceByDayProvider()

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近 7 天 Token 用量")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    if isScanning {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                        Text("计算中…")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else if let scannedAt {
                        Text("更新于 \(Formatters.formatClock(scannedAt))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                LocalUsageLegendDot(color: inputColor, title: "Input")
                LocalUsageLegendDot(color: cacheColor, title: "Cache")
                LocalUsageLegendDot(color: outputColor, title: "Output")
                LocalUsageLegendDot(color: reasonColor, title: "Reason")
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    let metrics = LocalUsageChartDayMetrics(day)
                    let uncachedHeight = CGFloat(25.6 * (Double(metrics.input) / chartScale.maxUncached))
                    let cachedHeight = CGFloat(
                        38.4 * (TokenChartScale.weight(for: metrics.cacheTotal) / chartScale.maxCachedWeight)
                    )
                    let outputHeight = CGFloat(64.0 * (metrics.outputChartValue / chartScale.maxOutputWeight))
                    let reasoningHeight = CGFloat(64.0 * (metrics.reasoningChartValue / chartScale.maxOutputWeight))

                    LocalUsageDayBar(
                        day: day,
                        uncachedHeight: uncachedHeight,
                        cachedHeight: cachedHeight,
                        outputHeight: outputHeight,
                        reasoningHeight: reasoningHeight,
                        inputColor: inputColor,
                        cacheColor: cacheColor,
                        outputColor: outputColor,
                        reasonColor: reasonColor
                    )
                }
            }
            .frame(maxWidth: .infinity)

            Divider().opacity(0.45)

            Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 4) {
                GridRow {
                    tableHeader("日期", width: 34, alignment: .leading)
                    tableHeader("R/T", width: 48, alignment: .trailing)
                    tableHeader("Input", width: 58, alignment: .trailing)
                    tableHeader("Cache", width: 58, alignment: .trailing)
                    tableHeader("Output", width: 58, alignment: .trailing)
                    tableHeader("Reason", width: 58, alignment: .trailing)
                    if priceByDay.isEmpty == false {
                        tableHeader("价值", width: 62, alignment: .trailing)
                    }
                }
                ForEach(days) { day in
                    let metrics = LocalUsageChartDayMetrics(day)
                    GridRow {
                        Text(Formatters.formatMonthDay(day.dayStart))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        roundsTurnsValue(day, width: 48)
                        tokenValue(metrics.input, color: inputColor, width: 58)
                        tokenValue(metrics.cacheTotal, color: cacheColor, width: 58)
                        tokenValue(metrics.output, color: outputColor, width: 58)
                        tokenValue(metrics.reasoning, color: reasonColor, width: 58)
                        if priceByDay.isEmpty == false {
                            priceValue(priceByDay[day.dayStart] ?? "—", width: 62)
                        }
                    }
                }
            }

            Text("输入：Uncached 线性缩放（占最大高度 40%），Cache 按 Token^0.3 缩放（占最大高度 60%）；输出线性缩放。R/T = rounds / turns。")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(width: priceByDay.isEmpty ? 390 : 420, alignment: .leading)
    }

    private func tableHeader(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func tokenValue(_ value: Int, color: Color, width: CGFloat) -> some View {
        Text(Formatters.formatTokenCountCompact(value))
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: width, alignment: .trailing)
    }

    private func priceValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(
                value == "未定价" || value.contains("部分计价") ? .orange : .secondary
            )
            .frame(width: width, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private func roundsTurnsValue(_ day: Daily, width: CGFloat) -> some View {
        let hasActivity = day.rounds > 0 || day.turns > 0
        let text = hasActivity
            ? "\(Formatters.formatGroupedInt(day.rounds))/\(Formatters.formatGroupedInt(day.turns))"
            : "—"
        return Text(text)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(hasActivity ? .primary : .secondary)
            .frame(width: width, alignment: .trailing)
    }
}

/// 单日柱图（泛型）—— 4 类 provider 数据共用，取代原来的 AntigravityDayBar /
/// DailyTokenUsageBarGroup / MinimaxDayBar。复用 ProviderCardView 里已有的
/// `StackedTokenBar` + `TokenBarSegment` 基础组件（无需重写柱体渲染）。
struct LocalUsageDayBar<Daily: LocalUsageDaily>: View {
    let day: Daily
    let uncachedHeight: CGFloat
    let cachedHeight: CGFloat
    let outputHeight: CGFloat
    let reasoningHeight: CGFloat
    let inputColor: Color
    let cacheColor: Color
    let outputColor: Color
    let reasonColor: Color

    var body: some View {
        let metrics = LocalUsageChartDayMetrics(day)

        VStack(spacing: 3) {
            Text(Calendar.current.isDateInToday(day.dayStart) ? "今天" : Formatters.formatMonthDay(day.dayStart))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .bottom, spacing: 4) {
                StackedTokenBar(
                    segments: [
                        TokenBarSegment(height: uncachedHeight, color: inputColor),
                        TokenBarSegment(height: cachedHeight, color: cacheColor),
                    ]
                )
                StackedTokenBar(
                    segments: [
                        TokenBarSegment(height: outputHeight, color: outputColor),
                        TokenBarSegment(height: reasoningHeight, color: reasonColor),
                    ]
                )
            }
            .frame(height: 64)

            VStack(spacing: 0) {
                Text("I \(Formatters.formatTokenCountCompact(metrics.inputTotal))")
                Text("O \(Formatters.formatTokenCountCompact(metrics.outputTotal))")
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(width: 55)
    }
}

/// hover 图表里的图例点（无泛型，4 色 legend 通用）
struct LocalUsageLegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// provider 卡片底部的"今日 token 用量"行（泛型）—— 4 类 provider 数据共用。
///
/// 取代了原来 3 个几乎一样的 view，并接入 OpenCode daily 数据：
/// - `AntigravityLocalUsageFooterView`
/// - `ChatGPTPlanLocalUsageFooterView`
/// - `MinimaxLocalUsageFooterView`（我刚加的）
///
/// 三个 provider 的 footer 差异只在 placeholder 文案 + "ready" 判断上：
/// - antigravity / minimax：`ready = dailyTokenUsage 非空`（任意一天有数据就能 hover）
/// - codex：`ready = dailyTokenUsage.count == 7`（必须 7 天满才能 hover，少于 7 天显示积累中）
/// 所以拆成：
/// - 共享的内联文案 + hover 触发（这里）
/// - provider 特定的 `emptyHint`（扫描完毕但 0 session 的提示）
/// - provider 特定的 `isReady`（caller 传 Bool 决定是否进 hover 模式）
struct LocalUsageFooterView<Daily: LocalUsageDaily>: View {
    let dailyTokenUsage: [Daily]
    let recentSamples: [LocalTokenUsageSample]
    let quotaProviderID: String
    let deepseekPeakWindow: DeepseekPeakWindow
    let scannedAt: Date?
    let isScanning: Bool
    let isReady: Bool
    /// "本机无 Antigravity 会话数据（~/.gemini/antigravity/conversations 为空）" 等
    /// provider 特定的"扫描完毕但还没数据"提示
    let emptyHint: String

    init(
        dailyTokenUsage: [Daily],
        recentSamples: [LocalTokenUsageSample] = [],
        quotaProviderID: String = "",
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow,
        scannedAt: Date?,
        isScanning: Bool,
        isReady: Bool,
        emptyHint: String
    ) {
        self.dailyTokenUsage = dailyTokenUsage
        self.recentSamples = recentSamples
        self.quotaProviderID = quotaProviderID
        self.deepseekPeakWindow = deepseekPeakWindow
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.isReady = isReady
        self.emptyHint = emptyHint
    }

    /// 不把数组顺序当作“今天”的依据；扫描器正常返回升序，但缓存或合并器
    /// 变化时仍应只展示当前自然日的数据。
    private var today: Daily? {
        dailyTokenUsage.last { Calendar.current.isDateInToday($0.dayStart) }
    }

    private var todaySamples: [LocalTokenUsageSample] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return []
        }
        return recentSamples.filter {
            $0.completedAt >= todayStart && $0.completedAt < tomorrow
        }
    }

    private var todayCostText: String {
        guard !todaySamples.isEmpty else { return "—" }
        let estimate = ModelPricingCatalog.estimate(
            samples: todaySamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        // displayText 统一处理“未定价 / 部分计价 / 全部计价”三种覆盖度。
        return estimate.displayText
    }

    private var priceByDay: [Date: String] {
        let estimates = ModelPricingCatalog.estimateByDay(
            samples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        return Dictionary(uniqueKeysWithValues: dailyTokenUsage.map { day in
            let key = Calendar.current.startOfDay(for: day.dayStart)
            let text: String
            if let estimate = estimates[key] {
                text = estimate.displayText
            } else {
                text = "—"
            }
            return (day.dayStart, text)
        })
    }

    @ViewBuilder
    private var todayMetrics: some View {
        if let today {
            HStack(spacing: 12) {
                todayMetric(label: "今天", value: "\(Formatters.formatTokenCountCompact(today.totalTokens)) tokens")
                todayMetric(label: "命中率", value: today.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                todayMetric(label: "价值", value: todayCostText)
            }
        } else {
            Text("今日暂无 Token 活动")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func todayMetric(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(Color.secondaryLabel)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }

    var body: some View {
        if isReady, !dailyTokenUsage.isEmpty {
            HoverInfoRow {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    todayMetrics
                }
            } detail: {
                SevenDayTokenUsageHoverView(
                    days: dailyTokenUsage,
                    scannedAt: scannedAt,
                    isScanning: isScanning,
                    priceByDay: priceByDay
                )
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 5) {
            if isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
            }
            Text(placeholderText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var placeholderText: String {
        if isScanning { return "正在扫描本地 token 用量…" }
        if dailyTokenUsage.isEmpty {
            return emptyHint
        }
        // codex 在数据未满 7 天时走这里（isReady=false 但已有部分数据）
        return "本地 token 用量数据积累中（\(dailyTokenUsage.count) / 7 天）"
    }
}

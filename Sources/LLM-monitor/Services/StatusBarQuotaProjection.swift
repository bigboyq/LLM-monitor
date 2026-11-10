import Foundation

/// The same catalog supplies picker options and the selected reading. Independent
/// balances never enter the global plan aggregate simply because they are visible.
struct StatusBarQuotaPool {
    enum Reading {
        case plan([StatusBarPlanModel])
        case single(StatusBarSingleQuota)
    }

    let option: StatusBarQuotaOption
    let reading: Reading
    var notice: String? = nil

    func metrics(alertThresholds: AlertThresholdConfig, at now: Date) -> StatusBarQuotaMetrics {
        switch reading {
        case .plan(let models):
            return StatusBarQuotaProjection.metrics(models: models, alertThresholds: alertThresholds, at: now)
        case .single(let quota):
            let health = quota.remainingFraction.map {
                alertThresholds.colorLevel(percent: $0 * 100, timeFraction: quota.timeRemainingFraction)
            }
            return StatusBarQuotaMetrics(
                weekly: .init(minAvailable: 0, avgAvailable: 0, isAvailable: false),
                interval: .init(minAvailable: 0, avgAvailable: 0, isAvailable: false),
                centerAvailable: quota.remainingFraction,
                quotaHealthLevels: health.map { [$0] } ?? [],
                centerTimeFraction: quota.timeRemainingFraction,
                alertThresholds: alertThresholds,
                singleQuota: quota
            )
        }
    }
}

struct StatusBarPlanModel {
    let kind: ProviderKind
    let model: ModelQuota
    let isPeak: Bool
}

enum StatusBarQuotaProjection {
    static func planTitle(models: [ModelQuota]) -> String {
        var labels: [String] = []
        for model in models {
            for (present, seconds, fallback) in [
                (model.hasIntervalWindow, model.intervalWindowSeconds, "5h"),
                (model.hasWeeklyWindow, model.weeklyWindowSeconds, "周")
            ] where present {
                let label: String
                switch seconds {
                case 18_000: label = "5h"
                case 604_800: label = "周"
                case .some(let seconds) where (28 * 86_400...31 * 86_400).contains(seconds): label = "月"
                case .some(let seconds) where seconds % 86_400 == 0: label = "\(seconds / 86_400)天"
                case .some(let seconds) where seconds % 3_600 == 0: label = "\(seconds / 3_600)h"
                case .some(let seconds): label = "\(seconds / 60)分钟"
                case nil: label = fallback
                }
                if !labels.contains(label) { labels.append(label) }
            }
        }
        return labels.isEmpty ? "主套餐" : labels.joined(separator: " / ")
    }

    /// Both the global relay and a selected main plan retain the existing physical
    /// window readings and effective-quota calculation. Layout follows window presence.
    static func metrics(
        models entries: [StatusBarPlanModel],
        alertThresholds: AlertThresholdConfig,
        at now: Date
    ) -> StatusBarQuotaMetrics {
        let models = entries.map(\.model)
        let intervalModels = models.filter(\.hasIntervalWindow)
        let weeklyModels = models.filter(\.hasWeeklyWindow)
        let interval = ringMetrics(intervalModels.map(\.intervalRemainingPercent))
        let weekly = ringMetrics(weeklyModels.map(\.weeklyRemainingPercent))

        var best: (percent: Double, bindingTimeFraction: Double?)?
        var hasReading = false
        for entry in entries {
            guard let reading = entry.model.aggregateActualAvailable(providerKind: entry.kind, at: now) else { continue }
            hasReading = true
            guard reading.percent > 0 else { continue }
            if best == nil || reading.percent < best!.percent { best = reading }
        }
        let available = best.map { $0.percent / 100 } ?? (hasReading ? 0 : nil)
        let timeFraction = best?.bindingTimeFraction
        let singleQuota: StatusBarSingleQuota? = intervalModels.isEmpty || weeklyModels.isEmpty
            ? StatusBarSingleQuota(remainingFraction: available, timeRemainingFraction: timeFraction)
            : nil

        return StatusBarQuotaMetrics(
            weekly: weekly,
            interval: interval,
            centerAvailable: available,
            quotaHealthLevels: entries.map {
                $0.model.aggregateHealthLevel(
                    providerKind: $0.kind,
                    isPeakPrice: $0.isPeak,
                    alertThresholds: alertThresholds,
                    at: now
                )
            },
            weeklyTimeFraction: weeklyModels.compactMap { $0.weeklyTimeRemainingFraction(at: now) }.max(),
            centerTimeFraction: timeFraction,
            intervalTimeFraction: intervalModels.compactMap { $0.intervalTimeRemainingFraction(at: now) }.max(),
            alertThresholds: alertThresholds,
            singleQuota: singleQuota
        )
    }

    private static func ringMetrics(_ percents: [Double]) -> QuotaRingMetrics {
        guard !percents.isEmpty else {
            return QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false)
        }
        let values = percents.map { min(max($0 / 100, 0), 1) }
        return QuotaRingMetrics(minAvailable: values.min()!, avgAvailable: values.reduce(0, +) / Double(values.count))
    }
}

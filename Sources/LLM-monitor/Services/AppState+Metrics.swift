import Foundation

extension AppState {
    var systemHealthLevel: HealthLevel? { systemHealthLevel(at: Date()) }

    func systemHealthLevel(at now: Date) -> HealthLevel? {
        // A chosen source owns the status-bar reading, including the SF Symbol dot.
        // Missing selected data is unknown; unrelated providers must not replace it.
        if configStore.config.statusBarQuotaSelection != nil {
            let metrics = statusBarQuotaMetrics(at: now)
            guard metrics.centerAvailable != nil else { return nil }
            return metrics.quotaHealthLevels.min()
        }
        let enabled = statuses.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        var levels: [HealthLevel] = []
        for status in enabled {
            switch status.state {
            case .failed(message: _, lastSuccess: nil): return .critical
            case .ok, .loading(lastSuccess: .some), .failed(message: _, lastSuccess: .some):
                if let level = status.aggregateHealthLevel(alertThresholds: configStore.config.effectiveAlertThresholds, at: now) {
                    levels.append(level)
                }
            case .notConfigured, .ready, .loading(lastSuccess: nil): break
            }
            if status.isGlmPeak(at: now) { levels.append(.warning) }
            if let peak = status.deepseekPeakWindow, case .peak = peak.status(at: now) { levels.append(.warning) }
        }
        return levels.min()
    }

    func statusBarQuotaMetrics(at now: Date = Date()) -> StatusBarQuotaMetrics {
        let thresholds = configStore.config.effectiveAlertThresholds
        if let selection = configStore.config.statusBarQuotaSelection {
            let pool = statusBarQuotaPools(providerID: selection.providerID, at: now)
                .first { $0.option.source == selection.source }
            return pool?.metrics(alertThresholds: thresholds, at: now)
                ?? StatusBarQuotaProjection.metrics(models: [], alertThresholds: thresholds, at: now)
        }
        // Only main plans enter the global relay. API credits and activity packages
        // are independent pools and participate exclusively through explicit selection.
        let models = fleetVisibleStatuses().filter { $0.kind != .deepseek }.flatMap { status in
            statusBarPlanModels(for: status, at: now)
        }
        return StatusBarQuotaProjection.metrics(models: models, alertThresholds: thresholds, at: now)
    }

    func statusBarQuotaOptions(providerID: String) -> [StatusBarQuotaOption] {
        statusBarQuotaPools(providerID: providerID, at: healthEvaluationDate).map(\.option)
    }

    func statusBarQuotaTitle(at now: Date = Date()) -> String {
        guard let selection = configStore.config.statusBarQuotaSelection else {
            return "全部 Provider · 非零最小有效额度"
        }
        let providerName = statuses.first { $0.id == selection.providerID }?.displayName
            ?? descriptors.first { $0.id == selection.providerID }?.displayName
            ?? selection.providerID
        guard let pool = statusBarQuotaPools(providerID: selection.providerID, at: now)
            .first(where: { $0.option.source == selection.source }) else {
            return "\(providerName) · \(selection.source.fallbackTitle) · 暂无数据"
        }
        let metrics = pool.metrics(alertThresholds: configStore.config.effectiveAlertThresholds, at: now)
        let value = metrics.centerAvailable.map { "剩余 \(Int(($0 * 100).rounded()))%" } ?? "暂无数据"
        return [providerName, pool.option.title, value, pool.notice].compactMap { $0 }.joined(separator: " · ")
    }

    private func statusBarPlanModels(for status: ProviderStatus, at now: Date) -> [StatusBarPlanModel] {
        guard status.isEnabled, status.kind != .deepseek,
              let info = fleetEffectiveQuota(for: status.kind).quota else { return [] }
        return info.aggregateQuotaModels(providerKind: status.kind).map {
            StatusBarPlanModel(kind: status.kind, model: $0, isPeak: status.isGlmPeak(at: now))
        }
    }

    /// Catalog adapters turn provider-specific data into independently selectable
    /// quota pools. Configuration supplies API identities even before their first fetch.
    private func statusBarQuotaPools(providerID: String, at now: Date) -> [StatusBarQuotaPool] {
        guard let status = fleetVisibleStatuses().first(where: { $0.id == providerID })
            ?? statuses.first(where: { $0.id == providerID }), status.kind != .deepseek else {
            return [.init(option: .init(source: .plan, title: "主套餐"), reading: .plan([]))]
        }
        let models = statusBarPlanModels(for: status, at: now)
        let activeModels = (status.isEnabled ? fleetEffectiveQuota(for: status.kind).quota?.activeModels : nil) ?? []
        let baseTitle = StatusBarQuotaProjection.planTitle(models: models.map(\.model))
        let planOptionTitle = activeModels.count > 1
            ? (baseTitle == "主套餐" ? "主套餐" : "主套餐 · \(baseTitle)")
            : baseTitle
        let notice = status.isEnabled ? fleetEffectiveQuota(for: status.kind).sourceTagText : "Provider 已停用"
        var pools = [StatusBarQuotaPool(
            option: .init(source: .plan, title: planOptionTitle),
            reading: .plan(models),
            notice: notice
        )]
        let planModelsToExpose: [ModelQuota]
        if activeModels.count > 1 {
            planModelsToExpose = activeModels
        } else if activeModels.count == 1,
                  let selection = configStore.config.statusBarQuotaSelection,
                  selection.providerID == status.id,
                  case .planModel(let selectedName) = selection.source,
                  selectedName == activeModels[0].modelName {
            planModelsToExpose = activeModels
        } else {
            planModelsToExpose = []
        }
        var seenModelNames = Set<String>()
        for model in planModelsToExpose where seenModelNames.insert(model.modelName).inserted {
            pools.append(StatusBarQuotaPool(
                option: .init(source: .planModel(modelName: model.modelName), title: model.displayName),
                reading: .plan([StatusBarPlanModel(kind: status.kind, model: model, isPeak: status.isGlmPeak(at: now))]),
                notice: notice
            ))
        }
        let config = configStore.config.providers[providerID]
        if status.kind == .codexChatGpt, config?.adminApiCreditsEnabled == true {
            for (index, key) in (config?.effectiveAdminKeys ?? []).enumerated() {
                let label = key.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = "API额度 · " + (label.isEmpty || label == "Default" ? "API Key #\(index + 1)" : label)
                let credit = status.isEnabled ? status.lastSuccess?.allOpenAIApiCredits.first { $0.keyId == key.id } : nil
                var fraction: Double?
                var time: Double?
                var notice: String?
                if let credit {
                    if credit.lastAttemptFailed == true && credit.fetchedAt == nil {
                        notice = "尚无成功读数"
                    } else if now < credit.cycleStart || now >= credit.cycleEnd {
                        notice = "账期已变化，等待刷新"
                    } else if credit.totalQuota.isFinite, credit.totalQuota > 0, credit.usedAmount.isFinite {
                        fraction = credit.remainingPercent / 100
                        time = credit.timeRemainingFraction(at: now)
                        notice = credit.lastAttemptFailed == true ? "可能过期" : nil
                    }
                }
                pools.append(StatusBarQuotaPool(
                    option: .init(source: .apiCredit(keyID: key.id), title: title),
                    reading: .single(.init(remainingFraction: fraction, timeRemainingFraction: time)),
                    notice: notice
                ))
            }
        }
        if status.kind == .glmCodingPlan, config?.isZcodeCredentialEnabled == true {
            for balance in status.glmActivityPlanBalances {
                let source = StatusBarQuotaSource.activityPlan(planID: balance.planID, entitlementID: balance.entitlementID)
                guard !pools.contains(where: { $0.option.source == source }) else { continue }
                let expired = balance.expiresAt.map { now >= $0 } ?? false
                let fraction: Double? = !status.isEnabled ? nil : expired ? 0 : balance.totalUnits > 0
                    ? min(max(Double(balance.remainingUnits) / Double(balance.totalUnits), 0), 1) : nil
                let title = [balance.planName, balance.showName].filter { !$0.isEmpty }.joined(separator: " · ")
                pools.append(StatusBarQuotaPool(
                    option: .init(source: source, title: title.isEmpty ? "Start Plan" : title),
                    reading: .single(.init(remainingFraction: fraction, timeRemainingFraction: nil)),
                    notice: expired ? "已到期" : nil
                ))
            }
            for preview in status.glmActivityPlanPreviews {
                let source = StatusBarQuotaSource.activityPlan(planID: preview.planID, entitlementID: preview.entitlementID)
                guard !pools.contains(where: { $0.option.source == source }) else { continue }
                let title = [preview.planName, preview.showName].filter { !$0.isEmpty }.joined(separator: " · ")
                pools.append(StatusBarQuotaPool(
                    option: .init(source: source, title: (title.isEmpty ? "Start Plan" : title) + "（待生效）"),
                    reading: .single(.init(remainingFraction: nil, timeRemainingFraction: nil)),
                    notice: "等待生效后的额度读数"
                ))
            }
        }
        return pools
    }
}

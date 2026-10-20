import Foundation

extension AppState {
    // MARK: - Antigravity local usage scanner

    @MainActor
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {
        applyLocalUsage(
            kind: .antigravity,
            field: \.antigravityLocalUsage,
            fieldName: "antigravityLocalUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - agy CLI local usage scanner（Antigravity 卡的本地用量贡献之一）

    @MainActor
    func applyAgyUsage(_ usage: AgyLocalUsage?) {
        applyLocalUsage(
            kind: .antigravity,
            field: \.agyUsage,
            fieldName: "agyUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - minimax local usage scanner

    @MainActor
    func applyMinimaxLocalUsage(_ usage: MinimaxLocalUsage?) {
        applyLocalUsage(
            kind: .minimaxTokenPlan,
            field: \.minimaxLocalUsage,
            fieldName: "minimaxLocalUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - GLM (ZCode) local usage scanner

    /// 把 ZCode 扫描结果挂到所有消费它的卡片。
    ///
    /// ZCode 是一份多 provider 账本：GLM 卡消费智谱系 native 用量（不受绑定
    /// 约束），MiniMax / DeepSeek 卡消费同一快照里的 `providerSlices` 分片
    /// （由 `clientBindings` 的 zcode → <quota> 绑定门控，见 `usageFrameExtractors`）。
    /// 与 `applyOpencodeUsage` 同样只挂快照、关闭绑定时诊断页仍可见。
    @MainActor
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {
        let changed = mutateStatuses { copy in
            var mutated = false
            for kind in Self.zcodeConsumerKinds {
                guard let providerID = providerID(for: kind),
                      let idx = copy.firstIndex(where: { $0.id == providerID }) else { continue }
                // GlmLocalUsage 自定义 == 排除 scannedAt
                if copy[idx].glmLocalUsage == usage { continue }
                copy[idx].glmLocalUsage = usage
                mutated = true
            }
            return mutated
        }
        if changed {
            let slices = usage?.providerSlices?.count ?? 0
            logDebug("[zcode/apply] slices=\(slices) sessions=\(usage?.sessionCount ?? 0)")
        }
    }

    /// 消费 ZCode 快照的卡片类型。智谱 native 用量进 GLM 卡，provider 分片进
    /// MiniMax / DeepSeek 卡。
    nonisolated static let zcodeConsumerKinds: [ProviderKind] = [
        .glmCodingPlan, .minimaxTokenPlan, .deepseek
    ]

    // MARK: - dsh local usage scanner（共享 session 日志 + 诊断页）

    @MainActor
    func applyDshUsage(_ usage: DshLocalUsage?) {
        let changed = mutateStatuses { copy in
            var mutated = false
            for idx in copy.indices {
                if copy[idx].dshUsage != usage {
                    copy[idx].dshUsage = usage
                    mutated = true
                }
            }
            return mutated
        }
        if changed {
            logDebug("[dsh/apply] providers=\(usage?.byProvider.count ?? 0), sessions=\(usage?.sessionCount ?? 0)")
            // 别名失配告警（P2）：dsh 帧的归属由 config 绑定别名解析，用户手改
            // config 写错 `sourceProviderAliases` 会让对应 provider 的用量静默漏采
            // （帧落空串组后被卡片过滤）。这里在快照落地时检测一次并打告警；
            // guard changed 之上不放——同一份快照只在首次落地时告警，不随渲染重复。
            let unclaimed = DshHarnessFrames.unclaimedProviderKeys(
                in: usage,
                bindings: configStore.config.clientBindings
            )
            if unclaimed.isEmpty == false {
                logWarn(
                    "[dsh/apply] 以下 dsh provider 键没有被任何 dsh 绑定别名认领，对应用量不会并入任何卡片："
                    + "\(unclaimed.joined(separator: ", "))；"
                    + "当前已登记别名（config clientBindings 的 sourceProviderAliases）："
                    + "\(DshHarnessFrames.registeredAliases(bindings: configStore.config.clientBindings).joined(separator: ", "))"
                )
            }
        }
    }

    // MARK: - opencode local usage scanner（GLM 卡 + 诊断页）

    /// 把 opencode 扫描结果分发到四个可能的 consumer provider status。
    /// opencode 自身不是 provider，所以 coordinator 的 setScanning 闭包是 no-op。
    @MainActor
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {
        mutateStatuses { copy in
            var mutated = false
            for kind in ProviderKind.allCases {
                guard let providerID = providerID(for: kind),
                      let idx = copy.firstIndex(where: { $0.id == providerID }) else { continue }
                let prev = copy[idx].opencodeUsage
                // OpencodeLocalUsage 自定义 == 排除 scannedAt
                if prev == usage { continue }
                copy[idx].opencodeUsage = usage
                mutated = true
            }
            return mutated
        }
    }

    /// 统一的"local usage apply"路径 —— antigravity / minimax (未来更多) 共享的
    /// 4 步逻辑：
    /// 1. 从 `descriptors` 找 providerID（key 来自 `kind`）
    /// 2. 在 `statuses` 里找 idx
    /// 3. no-op 检查（== 排除 `scannedAt` 之后基本命中，**不写 status、不触发 reload**）
    /// 4. 走 `mutateStatus` 改 `keyPath` 指向的字段
    @MainActor
    func applyLocalUsage<T: Equatable>(
        kind: ProviderKind,
        field: WritableKeyPath<ProviderStatus, T?>,
        fieldName: String,
        summarize: (T) -> String,
        usage: T?
    ) {
        let logTag = "[\(kind.logTag)/apply]"
        guard let providerID = providerID(for: kind) else {
            logWarn("\(logTag) apply aborted: no provider registered for kind .\(kind)")
            return
        }
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else {
            logWarn("\(logTag) apply aborted: providerID \(providerID) not in statuses")
            return
        }
        let prev = statuses[idx][keyPath: field]
        if prev == usage {
            logDebug("\(logTag) no-op: status[\(idx)].\(fieldName) already equals incoming value")
            return
        }
        let prevText = prev.map(summarize) ?? "nil"
        let newText = usage.map(summarize) ?? "nil"
        logDebug("\(logTag) reassigning statuses: \(fieldName) \(prevText) → \(newText)")
        // 走统一的 mutateStatus：copy → modify → assign + statusDidChange.send。
        mutateStatus(at: idx) { $0[keyPath: field] = usage }
        logDebug("\(logTag) done, status[\(idx)].\(fieldName)=\((statuses[idx][keyPath: field]).map(summarize) ?? "nil")")
    }
}

// MARK: - LocalUsageStatusWriting（本地扫描结果回写）

extension AppState: LocalUsageStatusWriting {}

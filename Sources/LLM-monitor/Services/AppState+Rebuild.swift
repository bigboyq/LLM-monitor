import Foundation

extension AppState {
    // MARK: - rebuildStatuses helpers

    /// rebuildStatuses 用的"保留字段"快照 —— 把旧 status 里不属于 config 派生的字段
    /// 集中提取，避免 `rebuildStatuses` 里 4 次 `statuses.first(where: { $0.id == ... })`。
    ///
    /// 不再包含 `lastSuccess` —— 它现在跟 `state` 绑在一起（`.ok(info)` /
    /// `.loading(lastSuccess:)` / `.failed(_, lastSuccess:)`），需要时直接拿
    /// `previousState` 整体复用。
    func preservedFields(for providerID: String) -> PreservedStatusFields {
        guard let old = statuses.first(where: { $0.id == providerID }) else {
            return PreservedStatusFields(
                lastRefreshedAt: nil,
                isScanningLocalUsage: false,
                localUsageFreshness: .clean,
                previousState: nil,
                antigravityLocalUsage: nil,
                minimaxLocalUsage: nil,
                glmLocalUsage: nil,
                opencodeUsage: nil,
                dshUsage: nil
            )
        }
        return PreservedStatusFields(
            lastRefreshedAt: old.lastRefreshedAt,
            isScanningLocalUsage: old.isScanningLocalUsage,
            localUsageFreshness: old.localUsageFreshness,
            previousState: old.state,
            antigravityLocalUsage: old.antigravityLocalUsage,
            minimaxLocalUsage: old.minimaxLocalUsage,
            glmLocalUsage: old.glmLocalUsage,
            opencodeUsage: old.opencodeUsage,
            dshUsage: old.dshUsage
        )
    }

    /// 从 config + auth probe 派生一个 provider 的 `State`。抽出成 static + 闭包注入
    /// fetcher 由 descriptor 工厂构造，因此测试可以直接注入 mock descriptor。
    static func deriveState(
        descriptor: FetcherDescriptor,
        providerConfig: ProviderConfig?,
        authProber: AuthProber?,
        hintProvider: (ProviderKind, ProviderConfig) -> String
    ) -> ProviderStatus.State {
        // R4: 真正的派生走类型化 ProviderDerivation；本方法保留 State 返回类型，
        // 把 .serviceOffline 折叠成 .notConfigured 以兼容历史调用方与测试。
        switch deriveProviderState(
            descriptor: descriptor,
            providerConfig: providerConfig,
            authProber: authProber,
            hintProvider: hintProvider
        ) {
        case .ready:
            return .ready
        case .notConfigured(let reason):
            return .notConfigured(reason: reason)
        case .serviceOffline(let message):
            return .notConfigured(reason: message)
        }
    }

    /// R4: 类型化派生结果，让 `rebuildStatuses` 能区分"配置/凭据确实无效"与
    /// "已配置但本地服务暂时不可用"，后者保留 lastSuccess 而不是清空。
    enum ProviderDerivation: Equatable {
        case ready
        case notConfigured(reason: String)
        case serviceOffline(message: String)
    }

    static func deriveProviderState(
        descriptor: FetcherDescriptor,
        providerConfig: ProviderConfig?,
        authProber: AuthProber?,
        hintProvider: (ProviderKind, ProviderConfig) -> String
    ) -> ProviderDerivation {
        let id = descriptor.id
        guard let pc = providerConfig else {
            logInfo("  [\(id)] 未在 config 中配置")
            return .notConfigured(reason: "未在 config.json 中配置")
        }
        if !pc.enabled {
            logInfo("  [\(id)] 在 config 中禁用")
            return .notConfigured(reason: "已在 config.json 中禁用")
        }
        if descriptor.kind == .glmCodingPlan {
            if pc.effectiveGlmAuthMode == .credential {
                let probe = descriptor.makeFetcher(pc)
                if !probe.hasLocalAuth() {
                    let hint = hintProvider(descriptor.kind, pc)
                    logInfo("  [\(id)] ZCode 本地凭证未就绪：\(hint)")
                    return .notConfigured(reason: hint)
                }
                logInfo("  [\(id)] ZCode 凭证 ok，state=ready")
                return .ready
            } else {
                guard pc.usableAPIKey != nil else {
                    logInfo("  [\(id)] API Key 未填写或为模板占位符")
                    return .notConfigured(reason: "API Key 未填写")
                }
                logInfo("  [\(id)] 配置 ok，state=ready")
                return .ready
            }
        }
        if descriptor.kind.usesExternalAuth {
            let probe = descriptor.makeFetcher(pc)
            if !probe.hasLocalAuth() {
                let hint = hintProvider(descriptor.kind, pc)
                logInfo("  [\(id)] 外部 auth 未就绪：\(hint)")
                return .notConfigured(reason: hint)
            }
            if descriptor.kind == .antigravity,
               let authProber,
               authProber.isUnavailable(id) {
                // R4: auth 文件在、配置启用，但本地 Antigravity 服务暂时不可用。
                // 与"凭据确实不存在"区分开：返回 serviceOffline，rebuildStatuses 会保留
                // lastSuccess 并以 .failed("Antigravity 本地服务离线") 展示。
                logInfo("  [\(id)] 后台探测到本地服务离线，保留 lastSuccess")
                return .serviceOffline(message: "Antigravity 本地服务离线")
            }
            logInfo("  [\(id)] 外部 auth ok，state=ready")
            return .ready
        } else {
            guard pc.usableAPIKey != nil else {
                logInfo("  [\(id)] API Key 未填写或为模板占位符")
                return .notConfigured(reason: "API Key 未填写")
            }
            logInfo("  [\(id)] 配置 ok，state=ready")
            return .ready
        }
    }

    /// R4: 从旧 State 提取 lastSuccess，供 serviceOffline 分支保留旧数据。
    nonisolated static func lastSuccessInfo(from state: ProviderStatus.State) -> QuotaInfo? {
        switch state {
        case .ok(let info):           return info
        case .loading(let prev):      return prev
        case .failed(_, let last):    return last
        case .notConfigured, .ready:  return nil
        }
    }
}

/// `rebuildStatuses` 内部用的 DTO —— 把"老 status 里需要保留的字段"打包。
struct PreservedStatusFields {
    let lastRefreshedAt: Date?
    let isScanningLocalUsage: Bool
    let localUsageFreshness: LocalUsageFreshnessSnapshot
    /// 旧 `state`，供 `rebuildStatuses` 决定是否复用（auth 还 ok 时直接保留
    /// `.ok/.loading/.failed` 状态 + 它的 QuotaInfo 数据）。
    let previousState: ProviderStatus.State?
    let antigravityLocalUsage: AntigravityLocalUsage?
    let minimaxLocalUsage: MinimaxLocalUsage?
    let glmLocalUsage: GlmLocalUsage?
    /// opencode 扫描快照（挂在各个 consumer status 上），跨 rebuildStatuses 保留
    /// 避免配置变更触发的那次 rebuild 抹掉刚扫到的共享用量导致 footer 闪空白。
    let opencodeUsage: OpencodeLocalUsage?
    let dshUsage: DshLocalUsage?
}

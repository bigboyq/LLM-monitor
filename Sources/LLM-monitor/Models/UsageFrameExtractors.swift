import Foundation

extension ProviderStatus {
    /// 每个 quota 卡的**帧抽取注册表**（取代旧的 contribution 工厂表）：
    /// `[kind: [帧抽取器]]`。每个抽取器把一个来源（status 字段 / QuotaInfo 详情）
    /// 转成 0..n 个 `HarnessUsageFrame`；返回空数组表示该来源当前无数据。
    ///
    /// 帧的顺序即贡献顺序（内核按首次出现的分组顺序输出），所以这里的数组顺序
    /// 是展示契约的一部分。新增 provider 只需在这里追一个抽取器。
    static let usageFrameExtractors: [ProviderKind: [@Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame]]] = [
        .codexChatGpt: [
            codexFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.openAIProviderID) { $0.opencodeUsage?.openAISlice }
        ],
        .antigravity: [
            antigravityFrames,
            agyFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.antigravitySourceProviderID) {
                $0.opencodeUsage?.antigravitySlice
            }
        ],
        .minimaxTokenPlan: [
            minimaxNativeFrames,
            dshFrames,
            zcodeSliceFrames(.minimax) { $0.glmLocalUsage?.minimaxSlice },
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.minimaxCodingPlanProviderID) {
                $0.opencodeUsage?.minimaxCodingPlanSlice
            }
        ],
        .glmCodingPlan: [
            zcodeNativeFrames,
            dshFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.glmProviderID) { $0.opencodeUsage?.glmSlice }
        ],
        .deepseek: [
            dshFrames,
            zcodeSliceFrames(.deepseek) { $0.glmLocalUsage?.deepseekSlice },
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.deepseekProviderID) { $0.opencodeUsage?.deepseekSlice }
        ]
    ]

    /// Codex native（`QuotaInfo.codexUsageDetails`）。样本已在 scanner 构造点带
    /// `codex:` 命名空间，这里保持原样。
    private static let codexFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { _, info in
        guard let details = info?.codexUsageDetails,
              let daily = details.dailyTokenUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.codex,
            quotaProviderID: QuotaProviderID.openAI,
            daily: daily,
            samples: details.recentSamples ?? [],
            namespace: .codex,
            scannedAt: details.scannedAt
        )]
    }

    /// Antigravity native（RPC + .db step 统计）。账本原始 promptID 是裸
    /// `session:turn`，投影时补 `antigravity:` 命名空间（规则见内核
    /// `UsageSampleNamespace.antigravityNative`）。
    private static let antigravityFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.antigravityLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.antigravity,
            quotaProviderID: QuotaProviderID.antigravity,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .antigravityNative,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// agy CLI（Antigravity 的命令行分支）本地 transcript 账本。帧自带
    /// quota 归属（`.antigravity`，与 antigravity native 同卡并列），账本原始
    /// promptID 是裸 `session:step`，投影时补 `agy:` 命名空间。截断位是快照级
    /// 口径（文件数/字节预算挤出最旧 session），整帧携带。
    private static let agyFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.agyUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.agy,
            quotaProviderID: QuotaProviderID.antigravity,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples,
            namespace: .agy,
            isTruncated: snapshot.isTruncated == true,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// MiniMax Code native（v2 runtime-state 单库 SQL）。裸 `session:turn`，
    /// 投影时补 `minimax-code:` 命名空间。
    private static let minimaxNativeFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.minimaxLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.minimaxCode,
            quotaProviderID: QuotaProviderID.minimax,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .minimaxNative,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// ZCode 智谱系 native（`GlmZcodeLocalUsageScanner`）。智谱行走 GLM 卡，
    /// 裸 `session:turn` 在投影时补 `zcode:` 命名空间；非智谱分片（多一段
    /// slice 键）见 `zcodeSliceFrames`。
    private static let zcodeNativeFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.glmLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.zcode,
            quotaProviderID: QuotaProviderID.zhipu,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .zcodeNative,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// DSH（共享 session 账本）→ 每 provider 键一帧。帧**不声明 quota 归属**：
    /// dsh 是多 provider 路由账本，归属与启停都由内核按 `status.clientBindings`
    /// 的 dsh 条目解析；本卡 quota 之外的组由 `usageProjection` 过滤。
    /// `isTruncated` 是快照级口径（文件数/字节预算挤出最旧 session），不随
    /// provider 分片稀释：每一帧都带快照的截断位，由内核做"任一截断即截断"。
    private static let dshFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        DshHarnessFrames.frames(from: status.dshUsage)
    }

    /// ZCode 账本里的非智谱 provider 分片（`minimax` / `deepseek`），并入
    /// MiniMax / DeepSeek 卡。由 `clientBindings` 的 zcode → <quota provider>
    /// 绑定门控（P2 起，取代旧 `mergeZcodeUsage` 派生 bool）。
    private static func zcodeSliceFrames(
        _ provider: ZcodeProviderSlice,
        _ slice: @escaping @Sendable (ProviderStatus) -> OpencodeProviderUsage?
    ) -> @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] {
        { status, _ in
            guard status.isClientBindingEnabled(
                    clientID: ClientID.zcode,
                    quotaProviderID: status.kind.quotaProviderID
            ),
                  let usage = slice(status) else { return [] }
            return [HarnessUsageFrame(
                clientID: ClientID.zcode,
                sourceKey: provider.providerPrefix,
                quotaProviderID: status.kind.quotaProviderID,
                daily: usage.dailyTokenUsage,
                samples: usage.recentSamples,
                namespace: .zcodeSlice,
                scannedAt: status.glmLocalUsage?.scannedAt
            )]
        }
    }

    /// OpenCode provider 分片（一份多 provider 账本）。由 `clientBindings` 的
    /// opencode → <quota provider> 绑定门控（P2 起，取代旧 `mergeOpencodeUsage`
    /// 派生 bool）；样本加 `opencode:<provider>:` 命名空间。
    private static func opencodeFrames(
        sourceProviderID: String,
        _ slice: @escaping @Sendable (ProviderStatus) -> OpencodeProviderUsage?
    ) -> @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] {
        { status, _ in
            guard status.isClientBindingEnabled(
                    clientID: ClientID.openCode,
                    quotaProviderID: status.kind.quotaProviderID
            ),
                  let usage = slice(status) else { return [] }
            return [HarnessUsageFrame(
                clientID: ClientID.openCode,
                sourceKey: sourceProviderID,
                quotaProviderID: status.kind.quotaProviderID,
                daily: usage.dailyTokenUsage,
                samples: usage.recentSamples,
                namespace: .opencode,
                scannedAt: status.opencodeUsage?.scannedAt
            )]
        }
    }
}

import Foundation

/// 客户端身份与绑定注册表（Models 层的纯事实源）。
///
/// 本文件只放"身份"语汇：client / quota provider 的稳定 ID、client 的注册表
/// 元数据，以及 client → quota 默认绑定的字面量表。它不依赖任何 Services /
/// 配置持久化类型——`AppConfig.defaultClientBindings` 只是这里的兼容再导出，
/// 事实源是 `ClientProviderBinding.defaultBindings`。

/// Stable IDs for the billing/quota side of the application.
///
/// These IDs intentionally do not describe where a token was generated. A
/// client can contribute usage to more than one quota provider.
enum QuotaProviderID {
    static let minimax = "minimax"
    static let openAI = "openai"
    static let antigravity = "antigravity"
    static let zhipu = "zhipu"
    static let deepseek = "deepseek"
}

/// Stable IDs for local applications that produce token usage.
enum ClientID {
    static let codex = "codex"
    static let antigravity = "antigravity"
    static let zcode = "zcode"
    static let openCode = "opencode"
    static let dsh = "dsh"
    static let minimaxCode = "minimax_code"
}

/// A client-to-quota relationship. The source aliases are normalized at the
/// scanner boundary; this type exists so the relationship is explicit instead
/// of being encoded as provider-specific `merge...` booleans.
struct ClientProviderBinding: Codable, Equatable, Identifiable, Sendable {
    let clientID: String
    let quotaProviderID: String
    var sourceProviderAliases: [String]
    var enabled: Bool

    var id: String { "\(clientID):\(quotaProviderID)" }

    init(
        clientID: String,
        quotaProviderID: String,
        sourceProviderAliases: [String] = [],
        enabled: Bool = true
    ) {
        self.clientID = clientID
        self.quotaProviderID = quotaProviderID
        self.sourceProviderAliases = sourceProviderAliases
        self.enabled = enabled
    }

    /// 默认 client → quota 绑定注册表。
    ///
    /// **数组里的字面量是归因别名的唯一事实源**（P2 显式化）：`OpencodeLocalUsage`
    /// 的 providerID 常量与 dsh 帧的路由匹配都从这里导出
    /// （`defaultSourceProviderAliases(clientID:quotaProviderID:)`），改别名只改这里。
    /// 注意不能反向引用 `OpencodeLocalUsage` 的常量——那些常量正是从本表导出的，
    /// 互相引用会形成静态初始化环。
    static let defaultBindings: [ClientProviderBinding] = [
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.minimax,
            sourceProviderAliases: ["minimax-cn-coding-plan"],
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            sourceProviderAliases: ["openai"],
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.antigravity,
            sourceProviderAliases: ["antigravity", "google-antigravity", "google-vertex", "google"],
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu,
            sourceProviderAliases: ["zhipuai-coding-plan"],
            enabled: true
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek,
            sourceProviderAliases: ["deepseek"],
            enabled: false
        ),
        // ZCode 是多 provider 共享账本：`minimax` / `deepseek` 的行与智谱系行
        // 同在 `model_usage` 表。默认开启（与 opencode → deepseek 的默认关闭相反）：
        // ZCode 的这两路 provider 是用户显式配置过的上游，凭空关掉只会让卡片少报
        // 一份已经真实发生的本地用量；要停用时把这两条改成 false 即可。
        ClientProviderBinding(
            clientID: ClientID.zcode,
            quotaProviderID: QuotaProviderID.minimax,
            sourceProviderAliases: [ZcodeProviderSlice.minimax.providerPrefix],
            enabled: true
        ),
        ClientProviderBinding(
            clientID: ClientID.zcode,
            quotaProviderID: QuotaProviderID.deepseek,
            sourceProviderAliases: [ZcodeProviderSlice.deepseek.providerPrefix],
            enabled: true
        ),
        // DSH 是一份多 provider 路由的 session 账本：帧不声明归属，由内核用这里的
        // 别名解析（contains 匹配、enabled 门控）。别名即旧 `DshHarnessFrames`
        // 硬编码路由表，语义不变，只是搬进唯一事实源。默认开启（与 DSH 历史上
        // 不受任何开关控制一致）。
        ClientProviderBinding(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            sourceProviderAliases: ["deepseek", "deepseek-official", "deepseek-cn", "deepseek-v4"],
            enabled: true
        ),
        ClientProviderBinding(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            sourceProviderAliases: ["minimax", "minimax-cn", "minimax-cn-coding-plan"],
            enabled: true
        ),
        ClientProviderBinding(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.zhipu,
            sourceProviderAliases: [
                "glm", "zhipu", "zhipuai", "bigmodel",
                "builtin:bigmodel-coding-plan", "account:bigmodel-individual-coding-plan"
            ],
            enabled: true
        )
    ]

    /// 从默认绑定导出 (clientID, quotaProviderID) 的归因别名。
    ///
    /// 唯一事实源是 `defaultBindings` 的数组字面量；查不到返回空数组，
    /// 调用方决定兜底（常量导出方用历史字面量兜底，并由一致性测试锁住不漂移）。
    static func defaultSourceProviderAliases(clientID: String, quotaProviderID: String) -> [String] {
        defaultBindings.first {
            $0.clientID == clientID && $0.quotaProviderID == quotaProviderID
        }?.sourceProviderAliases ?? []
    }
}

/// Registry metadata for a local client. This is deliberately independent of
/// `FetcherDescriptor`, which describes remote quota fetchers.
struct ClientDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let iconSystemName: String
    let supportedQuotaProviderIDs: [String]
    let subtitle: String

    static let all: [ClientDescriptor] = [
        ClientDescriptor(
            id: ClientID.codex,
            displayName: "Codex",
            iconSystemName: "terminal",
            // Codex CLI 当前只走 OpenAI ChatGPT Plan 一条 quota 通道。
            // DeepSeek / MiniMax 是预留路由：未来 Codex 增加对其它上游的支持时
            // 直接启用，不需要再改 ClientDescriptor 注册。
            supportedQuotaProviderIDs: [QuotaProviderID.openAI, QuotaProviderID.deepseek, QuotaProviderID.minimax],
            subtitle: "Codex 本地会话与 token 用量"
        ),
        ClientDescriptor(
            id: ClientID.antigravity,
            displayName: "Antigravity",
            iconSystemName: "paperplane.circle.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.antigravity],
            subtitle: "Antigravity 本地会话与 token 用量"
        ),
        ClientDescriptor(
            id: ClientID.zcode,
            displayName: "ZCode",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            // 智谱系行进 GLM 卡；同库里的 minimax / deepseek 行按分片并入对应卡
            // （开关见 clientBindings 的 zcode → minimax / deepseek 两条）。
            supportedQuotaProviderIDs: [
                QuotaProviderID.zhipu,
                QuotaProviderID.minimax,
                QuotaProviderID.deepseek
            ],
            subtitle: "ZCode 本地数据库用量"
        ),
        ClientDescriptor(
            id: ClientID.openCode,
            displayName: "OpenCode",
            iconSystemName: "terminal",
            supportedQuotaProviderIDs: [
                QuotaProviderID.openAI,
                QuotaProviderID.antigravity,
                QuotaProviderID.zhipu,
                QuotaProviderID.minimax,
                QuotaProviderID.deepseek
            ],
            subtitle: "多 Provider 本地 token 账本"
        ),
        ClientDescriptor(
            id: ClientID.dsh,
            displayName: "DSH",
            iconSystemName: "terminal.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.deepseek, QuotaProviderID.minimax, QuotaProviderID.zhipu],
            subtitle: "多 Provider session token 账本"
        ),
        ClientDescriptor(
            id: ClientID.minimaxCode,
            displayName: "MiniMax Code",
            iconSystemName: "bubble.left.and.text.bubble.right.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.minimax, QuotaProviderID.openAI, QuotaProviderID.deepseek],
            subtitle: "MiniMax Code 本地用量"
        )
    ]

    /// 展示名（`ClientUsageContribution.displayName` / 设置页行标题共用）。
    /// 未登记的 clientID 回退成 ID 本身，避免出现空标题。
    static func displayName(forClientID clientID: String) -> String {
        all.first { $0.id == clientID }?.displayName ?? clientID
    }
}

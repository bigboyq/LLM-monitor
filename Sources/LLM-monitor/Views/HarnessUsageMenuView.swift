import SwiftUI

/// 状态栏下拉菜单的 **Harness（客户端）视角**内容：顶部一屏全局今日汇总，
/// 下面按客户端分段、段内按模型一行一条，**最底部一行 provider 兜底状态**。
///
/// 与 `ProviderCardView`（Provider 视角）是**并列**的两套读法，不是替换关系：
/// 悬浮窗（边缘状态窗）仍然按 Provider 卡渲染额度，菜单这里只回答"今天我在哪些
/// 客户端里烧了多少 token、命中率多少、值多少钱"。额度（还能用多少）不再占一整屏，
/// 但**不能从这一屏彻底消失**——否则没开边缘窗的用户在菜单里看不到任何额度信息；
/// 底部的 `ProviderStatusStripView` 一行极简状态元素 + hover 弹出的完整卡片就是
/// 这一层兜底。
///
/// 排版宽度（菜单 360pt，内容区 336pt，见 `MenuPanelHeightBridge.width`）：
/// 模型名 ≤108 + 占比条 ≥72 + Token 40 + 命中 36 + 价值 48 + 4×6 间距 = 328pt，
/// 余量 8pt 留给字体度量误差。数字列全部定宽右对齐 + `monospacedDigit`，刷新时
/// 数字变化不会把整行往右顶。预算由 `HarnessUsageMenuViewTests` 钉住。
struct HarnessUsageMenuView: View {
    let summary: HarnessTodaySummary
    /// 底部的 provider 兜底行（见 `ProviderStatusStripView`）。空快照不渲染任何东西。
    var providerStrip: ProviderStatusStrip.Snapshot = ProviderStatusStrip.Snapshot(entries: [], hiddenCount: 0)
    /// 段头右键菜单的两条动作。默认空实现：菜单内容在任何只读渲染（测试、预览）
    /// 里都能构造，右键菜单的存在与否由调用方决定。
    var onRefreshAll: () -> Void = {}
    /// 兜底行单个 provider 的「刷新该 Provider」动作。参数是 providerID，
    /// 刷新实现由 `MenuContentView` 注入（它持有 `AppState`）。
    var onRefreshProvider: (String) -> Void = { _ in }
    /// 是否正有刷新事务在飞。透传给兜底行：刷新期间把单刷菜单项置灰，
    /// 口径与 header 那个转圈按钮同源（`AppState.isRefreshJobActive`，全局粒度，
    /// 不是单卡粒度——单卡粒度这套状态里没有，不硬造）。
    var isRefreshJobActive: Bool = false
    var onOpenConfigFile: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessUsageMenuView.sectionSpacing) {
            todayOverview
            if summary.sections.isEmpty {
                emptyTodayState
            } else {
                ForEach(summary.sections) { section in
                    HarnessSectionView(
                        section: section,
                        onRefreshAll: onRefreshAll,
                        onOpenConfigFile: onOpenConfigFile
                    )
                }
            }
            ProviderStatusStripView(
                snapshot: providerStrip,
                onRefreshProvider: onRefreshProvider,
                isRefreshJobActive: isRefreshJobActive
            )
        }
    }

    // MARK: - 全局今日汇总

    /// 顶部一屏结论：今天一共烧了多少、缓存命中率多少、折算成 CNY 值多少，
    /// 底下一行三段占比条给出这批 token 的构成（input / cacheRead / output）。
    ///
    /// 数字行（第一行）从左到右：标签 / 总 token（定宽）/ 命中率（裸值，定宽）/
    /// 价值（撑满、右对齐）/ 裸刷新时间。宽度核算见下方各常量与
    /// `HarnessUsageMenuViewTests.testTodayOverviewRowFitsItsInnerWidth`。
    private var todayOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("今日合计")
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(Color.secondaryLabel)
                // 定宽：token 数位变化不该把右边两列推来推去。
                Text(Formatters.formatTokenCountCompact(summary.totalTokens))
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(Color.primaryLabel)
                    .frame(width: HarnessUsageMenuView.totalWidth, alignment: .leading)
                Spacer(minLength: 4)
                // 命中率是裸值（`100%` / `—`），不再带「命中」前缀：一行的读者已经
                // 知道这列是什么，省下的 20pt 留给混币价值与刷新时间。
                Text(Self.hitRateText(summary.cacheHitRate))
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(width: HarnessUsageMenuView.hitRateWidth, alignment: .trailing)
                // 混合币种文案（`53270.9（含$7610)`）比单币种长得多，这里吃剩余
                // 空间而不是定宽——定宽会把混币总额折成两行。
                Text(summary.valueText)
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                // 行尾刷新时间是**裸文本**（HH:mm，跨天退化成 `MM-dd HH:mm`），不带
                // 「更新于」前缀与胶囊底色——数字行没有胶囊的宽度预算。颜色语义与
                // 「计算中…」状态由 `LocalUsageFreshnessText` 保持在悬浮窗 7 天卡那枚
                // 胶囊（`LocalUsageFreshnessBadge`）的同款。时间自然宽、不压缩：空间
                // 不足时先被截断的是上面的混币价值（tail），时间格始终完整可读。
                LocalUsageFreshnessText(
                    scannedAt: summary.localUsageScannedAt,
                    isScanning: summary.isScanningLocalUsage
                )
            }
            // 占比条独占一整行：数字行已经放不下任何徽标（见上），而占比条是
            // `GeometryReader`（贪婪），独占整行也让三段比例的读数更宽。
            TokenBucketBar(buckets: summary.buckets)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 客户端有本地账本、只是今天还没跑过模型时的占位。与上面"没注册 provider"
    /// 的两级空态是不同层级：数据在，只是今天为空。
    private var emptyTodayState: some View {
        Text("今日暂无本地 Token 用量")
            .font(MenuTypography.metricLabel)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    // MARK: - 排版常量

    /// 命中率文案：分母为 0（没有 input / cacheRead）显示「—」。
    static func hitRateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.0f%%", rate * 100)
    }

    /// 段与段之间的间距。段内行距更紧（`HarnessModelRowView.rowSpacing`），
    /// 让"换了一个客户端"在视觉上比"换了一个模型"更明显。
    static let sectionSpacing: CGFloat = 10
    /// 今日总 token 列定宽。`1,041M`（六字符）是最宽的常见形态。
    static let totalWidth: CGFloat = 56
    /// 命中率列定宽（今日合计行的**裸值**）。`100%` 实测自然宽 30pt，留 2pt 余量。
    static let hitRateWidth: CGFloat = 32
    /// 段价值列定宽。与模型行的价值列同宽，两个"价值"数字右对齐成一条竖线。
    static let valueWidth: CGFloat = 56
}

/// 一个客户端段：段头（名称 + 今日小计 + 段价值）+ 段内模型行。
///
/// **internal 而非 private**：留下测试缝。`HarnessUsageMenuViewTests` 要真的把
/// 一个段布局一遍量高度与自然宽（列宽超预算、单个段撑爆菜单高度都只能这么抓），
/// 改回 private 就得把同样的量测挂在 `HarnessUsageMenuView` 上，量的就不再是
/// 真正被渲染的那棵树了。同一约定见 `SettingsView.clientProviderDisclosure`。
struct HarnessSectionView: View {
    let section: HarnessSection
    /// 段头右键菜单的两条动作（刷新 / 打开配置文件）。
    var onRefreshAll: () -> Void = {}
    var onOpenConfigFile: () -> Void = {}

    var body: some View {
        // 行距取行视图自己的常量（比段间距小），"换了个客户端"才比"换了个模型"醒目。
        VStack(alignment: .leading, spacing: HarnessModelRowView.rowSpacing) {
            header
            ForEach(section.rows) { row in
                HarnessModelRowView(row: row)
            }
        }
    }

    /// 段头：一行里同时给出"这是谁"和"今天它花了多少"。
    /// 段价值是 `MixedCurrencyEstimate`——同一个客户端横跨多个 provider 分片时
    /// （OpenCode / DSH / ZCode）必然混币，必须折算成 CNY 总额而不是裸相加。
    ///
    /// 右键菜单挂在**段头**（不是整段）：菜单内容区现在是客户端视角，右键一个
    /// 段名才是"针对这些数据"的语义；两条动作沿用改造前 provider 卡的同名动作
    /// （刷新全部 / 打开配置文件），动作实现由 `MenuContentView` 注入。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: section.iconSystemName)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                Text(section.displayName)
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Formatters.formatTokenCountCompact(section.totalTokens))
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(Color.secondaryLabel)
                Text(section.valueText)
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(Color.primaryLabel)
                    .frame(width: HarnessUsageMenuView.valueWidth, alignment: .trailing)
            }
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) {
                MenuHairline.horizontal
            }
            .contextMenu {
                Button("立即刷新全部", action: onRefreshAll)
                Button("打开配置文件", action: onOpenConfigFile)
            }
            // 截断提示只在该段的数据源真的被截断时出现：数字本身仍然是"对"的，
            // 只是"不全"——不说就等于把一份残缺统计当完整统计读。
            if section.isTruncated {
                truncationNotice
            }
        }
    }

    /// 橙色截断提示，**单行**短文案。
    ///
    /// 完整说明是 `ClientUsageTruncationNotice.text`（设置页展开行与 7 天柱图
    /// footer 用的那一句），但那一句二十多个字，在段头底下 336pt 宽的位置要占两行，
    /// 而菜单里这一行的读者只需要知道"数字不全"——具体怎么截断的，鼠标悬停
    /// （`.help`）再看。
    static let truncationShortText = "部分较早会话未计入"

    private var truncationNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.orange)
            Text(Self.truncationShortText)
                .font(MenuTypography.hint)
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .help(ClientUsageTruncationNotice.text)
        }
    }
}

/// 菜单内容区**底部**的 provider 兜底行：一行横排全部已启用 provider 的极简状态
/// 元素（品牌图标 + `ProviderStateLabel` 胶囊，红/黄/绿新鲜度）。
///
/// 它存在的理由：菜单主体已经改成客户端视角（"今天烧了多少"），**额度**那一面
/// 只剩边缘状态窗与设置页；没开边缘窗的用户在这一屏就彻底看不到额度状态了。
/// 这一行把它兜回来，且**不与 harness 段混淆**——独立一行（无文字标题，图标 +
/// 状态胶囊的序列自解释），不占段头、不进段的行序。
///
/// hover 任一元素 → 独立 `NSPanel` 弹出**完整 `ProviderCardView(status:)`**
/// （`HoverInfoRow` + `HoverPanelController`，与菜单里其它 hover 详情同一机制）。
/// 卡片按 `.alwaysVisible` 渲染：浮层 `ignoresMouseEvents = true`，在里面再要求
/// "悬停才展开"等于要求一个正在被移开的窗口被悬停，那些折叠区永远展不开
/// （与 `EdgeDockController+Popover.popoverContent` 同一理由）。
///
/// 一个元素上叠着**三种交互**，分工是：
///
/// - **左键点按** → 立即刷新这一个 provider。菜单主体改成客户端视角后，这一行
///   元素是面板上唯一能"左键点到某个具体 provider"的地方：hover 浮层
///   `ignoresMouseEvents` 穿透、点不了，header 的「立即刷新全部」范围又太大。
///   连点的安全性由 `AppState.refreshOne` 的全局在飞闸门兜（见下），UI 侧
///   不做禁用态。
/// - **右键** → 「刷新 <provider>」菜单项。同一个动作的显式入口，适合"我知道
///   我要点哪个"的场景；与左键走**同一份** `RefreshMenuItem`（`refreshMenuItem(for:)`），
///   两条路只有一个区别：怎么触发。
/// - **hover** → 弹完整卡，纯只读，**不触发任何网络请求**。
struct ProviderStatusStripView: View {
    let snapshot: ProviderStatusStrip.Snapshot
    /// 单个 provider 的「刷新该 Provider」。参数是 providerID，实际刷新路径由
    /// 宿主（`MenuContentView` → `AppState.refreshOne`）决定，这一层不碰网络。
    var onRefreshProvider: (String) -> Void = { _ in }
    /// 刷新事务在飞时把菜单项置灰，避免连点叠加。全局粒度，同 header 刷新按钮。
    var isRefreshJobActive: Bool = false

    /// 右键菜单项 / 左键点按**共用**的这份动作的**数据形态**（不含 SwiftUI 视图）。
    ///
    /// 单独提成值类型，是为了让"菜单项标题长什么样""点下去交出去的是不是这张
    /// provider 的 id"这两条可以被单测钉住：contextMenu 的 `Button` 与
    /// `onTapGesture` 在 SwiftUI 里都没有可寻址的测试缝，断言只能落在喂给它们的
    /// 这份数据与 `perform` 的路由上。
    struct RefreshMenuItem: Identifiable, Equatable, Sendable {
        let providerID: String
        let displayName: String
        var id: String { providerID }
        /// 菜单文案。旧 provider 卡的单刷项叫「立即刷新」，这里带上 provider 名，
        /// 因为一行里有多枚同款菜单项，不带名用户分不清点的是哪一个。
        var title: String { "刷新 \(displayName)" }
        /// 执行：把 providerID 原样交回宿主。
        func perform(_ onRefresh: (String) -> Void) {
            onRefresh(providerID)
        }
    }

    /// 单个 provider 元素对应的单刷动作。**在场即有**——`.failed` /
    /// `.notConfigured` 的 provider 同样能点，因为"重试"正是它们需要的动作。
    static func refreshMenuItem(for entry: ProviderStatusStrip.Entry) -> RefreshMenuItem {
        RefreshMenuItem(providerID: entry.status.id, displayName: entry.displayName)
    }

    /// 左键点按的动作闭包。与右键菜单项**共用同一个 `RefreshMenuItem`**——
    /// 两条交互只有一个区别：怎么触发，执行路径（providerID → 宿主注入的刷新
    /// 闭包 → `AppState.refreshOne`）完全共用，不各写一份。
    ///
    /// 提成 `static` 是**测试缝**：`onTapGesture` 在 SwiftUI 里没有可寻址的接口，
    /// 「点按交出去的是不是这张 provider 的 id」只能钉在这个闭包上。
    static func tapHandler(
        for item: RefreshMenuItem,
        onRefresh: @escaping (String) -> Void
    ) -> () -> Void {
        { item.perform(onRefresh) }
    }

    /// 元素之间的间距。比模型行的 6pt 紧一档：这一行是**兜底**信息，不该在
    /// 视觉上比正文行还松。
    static let entrySpacing: CGFloat = 4

    /// hover 卡宽度：与 dock 浮层那张卡**逐像素同宽**
    /// （`EdgeDockTheme.popoverWidth` 减去背板内边距）。写死成菜单宽度会让 7 天
    /// 图表的 420pt 内容被压掉一截——dock 侧当初就是因为这个才把宽度从 360
    /// 推到 `popoverWidth` 的。
    static var cardWidth: CGFloat {
        EdgeDockTheme.popoverWidth - EdgeDockTheme.popoverPadding * 2
    }

    /// hover 卡的折叠方式，**必须钉死成 `.alwaysVisible`**。
    ///
    /// `HoverPanelController` 的浮层 `ignoresMouseEvents = true`：它**收不到**鼠标
    /// 事件，所以卡里那些「悬停才展开」的部分永远展不开。不钉这个值时（环境默认
    /// 是 `.onHover`）弹出来的是一张缺重置卡、缺高峰期倒计时、额度行也是简版的卡
    /// ——比不弹还糟。理由与 `EdgeDockController+Popover.popoverContent` 完全一致。
    ///
    /// 提成常量是为了让 `HoverRevealModeTests` 能直接断言"兜底行用的是哪一种"，
    /// 而不是只能对着视图猜。
    static let cardRevealMode: HoverRevealMode = .alwaysVisible

    /// 品牌图标边长。常规 18pt 在这一行太大：一行要放下
    /// `ProviderStatusStrip.maximumVisibleCount` 个元素，18pt 图标会把时间胶囊
    /// 挤到只剩 30pt。11pt 仍能认出是哪个品牌。
    static let logoSize: CGFloat = 11

    var body: some View {
        if !snapshot.isEmpty {
            // 不带文字标签：一行「品牌图标 + 状态胶囊」的序列自解释（红/黄/绿胶囊
            // 的语义由 `ProviderStateLabel` 承载），去掉约 74pt 的标签换来的宽度
            // 正好把可见容量从 4 个 provider 放到 5 个（核算见
            // `ProviderStatusStrip.maximumVisibleCount`）。
            HStack(spacing: Self.entrySpacing) {
                ForEach(snapshot.entries) { entry in
                    entryView(entry)
                }
                // 有 provider 被折叠掉时必须说出来：否则"只显示 3 个"会被读成
                // "只注册了 3 个"。
                if snapshot.hiddenCount > 0 {
                    Text("+\(snapshot.hiddenCount)")
                        .font(MenuTypography.badge)
                        .foregroundStyle(Color.secondaryLabel)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .help("还有 \(snapshot.hiddenCount) 个已启用 provider 未显示：额度异常优先占位")
                }
            }
            .padding(.top, 2)
            .overlay(alignment: .top) {
                MenuHairline.horizontal
                    .padding(.bottom, 2)
            }
        }
    }

    /// 单个 provider 的极简元素 + 它的完整卡浮层，以及叠在元素上的三种交互。
    ///
    /// 右键菜单挂在**整个元素**上（不是浮层里的卡）：菜单改版成客户端视角后，
    /// 这一行是菜单里唯一还带 provider 身份的地方，单刷入口必须回到这里——
    /// 旧 provider 卡的「立即刷新」是 3b3538e 随卡片一起下线的。
    ///
    /// 手势的挂载点说明（为什么这样挂不互相破坏）：
    /// - `onTapGesture` 挂在 `HoverInfoRow` **外面**：它加的是 SwiftUI 手势识别，
    ///   而 hover 走的是 `HoverTrackingView` 的 NSView tracking area，两条通道互不
    ///   干涉，hover 弹卡照旧。命中区域直接沿用 `HoverInfoRow` 自己那层
    ///   `contentShape`（6pt 圆角矩形），已经盖住图标与胶囊之间那 3pt 缝。
    /// - `contextMenu` 同样挂在外面：右键是独立事件路径，与左键手势不冲突。
    /// - **不做 `isRefreshJobActive` 置灰**（右键菜单项做了）：重复点按交出去的还是
    ///   同一个 `AppState.refreshOne`，它开头就有全局在飞闸门
    ///   （`refreshScheduler.beginExternalJob()`，在飞则整次忽略并只重锚被刷的
    ///   provider）。UI 再维护一份"这一行点不动"的状态只会和 `isRefreshJobActive`
    ///   的全局口径漂移，而且用户连点时看到"没反应"比看到"已在刷新"更困惑——
    ///   反馈交给既有状态胶囊自然变化（更新中 → HH:mm）。
    private func entryView(_ entry: ProviderStatusStrip.Entry) -> some View {
        let item = Self.refreshMenuItem(for: entry)
        return HoverInfoRow {
            HStack(spacing: 3) {
                BrandLogoView(kind: entry.status.kind, size: Self.logoSize)
                ProviderStateLabel(status: entry.status)
            }
        } detail: {
            ProviderCardView(status: entry.status)
                .environment(\.hoverRevealMode, Self.cardRevealMode)
                .environment(\.quotaWindowSegmentEditable, false)
                .frame(width: Self.cardWidth)
        }
        .onTapGesture(perform: Self.tapHandler(for: item, onRefresh: onRefreshProvider))
        .contextMenu {
            Button(item.title) {
                item.perform(onRefreshProvider)
            }
            .disabled(isRefreshJobActive)
        }
    }
}

/// 段内单条模型行：模型名 + 三段占比条 + Token / 命中率 / 价值。
///
/// 价值是**行级**的 `ModelCostEstimate.displayText` 原样文案（单 provider 单币种
/// 原额）。行级绝不做跨币种相加——同一段里不同 provider 的行金额可能不同币种，
/// 相加必须留到段头 / 全局的 `MixedCurrencyEstimate`。
/// 与 `HarnessSectionView` 同一条理由保持 internal：排版预算断言要直接读它的
/// 定宽列常量。
struct HarnessModelRowView: View {
    let row: HarnessModelRow

    /// 行与行的间距。刻意小于段间距（`sectionSpacing`），让分组层级一眼可辨。
    static let rowSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: 6) {
            // 模型名**定宽**，不是 `maxWidth`：同行的 `TokenBucketBar` 内部是
            // `GeometryReader`（贪婪填充），不定宽的名字列会被它整列吃掉——实测
            // 模型名会宽到 0pt，整行只剩条和数字。名字定宽 + 条吃剩余，是这里
            // 唯一稳定的分法。展示用压缩名（去品牌前缀，让变体后缀可区分），
            // hover 提示兜底完整原始 ID。
            Text(row.compactDisplayName)
                .font(MenuTypography.modelTitle)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.displayName)
                .frame(width: HarnessModelRowView.modelNameWidth, alignment: .leading)
            TokenBucketBar(buckets: row.buckets)
                .frame(minWidth: HarnessModelRowView.bucketBarMinWidth, maxWidth: .infinity)
            Text(Formatters.formatTokenCountCompact(row.totalTokens))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.tokenWidth, alignment: .trailing)
            Text(HarnessModelRowView.percentText(row.cacheHitRate))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.hitRateWidth, alignment: .trailing)
            Text(row.costText)
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: HarnessModelRowView.valueWidth, alignment: .trailing)
        }
    }

    // MARK: - 排版常量

    /// 模型名列定宽。长模型名（`claude-sonnet-4-5-20250929-thinking`）走 tail
    /// 截断，保留最有辨识度的前缀。
    ///
    /// 五列合计 100 + 72 + 40 + 36 + 56 = 304pt，加 4 段 6pt 间距 = 328pt，
    /// 在 336pt 内容区里留 8pt 余量给字体度量误差——数字列都是定宽右对齐，
    /// 余量被吃掉也只是让占比条窄一点，不会串列。
    static let modelNameWidth: CGFloat = 100
    /// 占比条下限：模型名列再长也要留住能看出三段比例的宽度。
    static let bucketBarMinWidth: CGFloat = 72
    /// Token 列定宽。`formatTokenCountCompact` 的最宽形态是五字符的 `9,999`
    /// （≥10000 走 `10K` / `1.2M` 阶梯），10pt 等宽数字下 40pt 够。
    static let tokenWidth: CGFloat = 40
    /// 命中率列定宽。`100%` 是最宽形态。
    static let hitRateWidth: CGFloat = 36
    /// 价值列定宽。`$1234.56`（八字符，实测最宽的常见形态）走定宽；
    /// `（部分计价）` 之类更长的文案走 middle 截断，而不是把整行往左挤。
    static let valueWidth: CGFloat = 56

    /// 命中率文案复用汇总块的同一实现，避免两处小数位规则漂移。
    static func percentText(_ rate: Double?) -> String {
        HarnessUsageMenuView.hitRateText(rate)
    }
}

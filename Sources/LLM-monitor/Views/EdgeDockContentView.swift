import SwiftUI

extension AccentColor {
    /// provider 粒度的品牌色。边缘窗已改用真实品牌图标（`BrandLogoView`），
    /// 这个映射保留给其它复用点。
    var tintColor: Color {
        switch self {
        case .minimax:     return .minimaxBrand
        case .chatgpt:     return .chatgptBrand
        case .antigravity: return .antigravityGemini
        case .glm:         return .glmBrand
        case .deepseek:    return Color(red: 0.20, green: 0.36, blue: 0.85)
        case .custom:      return .secondary
        }
    }
}

/// 边缘状态窗的内容：一列 provider 双环。
///
/// 结构由外向内三层：
/// - **外环** = 5h 有效额度（min(5h 剩余, 周剩余 × 周等效倍率 N)，与状态栏中心扇形同口径，
///   见 `EdgeDockProjection.intervalFraction`）
/// - **内环** = 周窗口剩余比例
/// - **中心** = Provider 品牌图标（`BrandLogoView`，与菜单卡片同源）
///
/// 背景用 `EdgeDockTab`：贴屏幕那一侧是直角、与屏幕边缘连成一条线；
/// 朝屏幕内侧那一端是大圆角。
///
/// hover 交互**不在这里用 `.onHover`**：窗口默认 `ignoresMouseEvents = true`，
/// 这个状态下 SwiftUI 收不到 hover 事件。命中判定由
/// `EdgeDockController.hoveredIndex`（系统级事件监听算出）驱动，
/// 这里只负责把高亮画出来；详情由 dock 旁边独立的 popover 展示。
/// 曾经挂过 `.help(...)` tooltip，但穿透态下几乎无法触发，已随 VoiceOver
/// 文案保留策略一并撤掉（见 `caption(for:)`）。
struct EdgeDockContentView: View {
    @ObservedObject var controller: EdgeDockController
    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore

    /// 官方广播通道（`@Published statuses` 在本项目实测失效）+
    /// 高峰边界时钟。两者都是"状态变了但没有任何抓取发生"的兜底。
    @State private var tick: UInt64 = 0

    /// 条目顺序 = 配置里的 provider 顺序（与菜单卡片一致，见 `orderedEntries`）。
    private var entries: [EdgeDockEntry] {
        _ = tick
        return EdgeDockProjection.entries(
            from: state.statuses,
            preferredIDs: configStore.config.providerCardOrder
        )
    }

    private var healthColors: StatusBarHealthColors {
        configStore.config.effectiveStatusBarHealthColors
    }

    /// 收起形态当前这一档的尺寸。
    ///
    /// 读 `controller.config`（而不是 `configStore.config`）：窗口尺寸、命中兜底、
    /// popover 定位全部读的是控制器那份**已发布**的运行时配置，而内容必须和它们
    /// 逐帧一致。`configStore.$config` 的订阅是 `receive(on: DispatchQueue.main)`
    /// ——一次异步跳转，在那段空窗里两边读到的是两个值，内容会先按新尺寸排好、
    /// 窗口还停在旧尺寸，正好是"同曲线同时长"要防的错位帧。
    private var compactMetrics: EdgeDockGeometry.CompactMetrics {
        EdgeDockGeometry.compactMetrics(for: controller.config.compactSize)
    }

    /// 完整↔简版变形的动画驱动值。
    ///
    /// `.animation(_:value:)` 只在 `value` **变了**时播放。原来这个 value 是
    /// `isCompactAppearance`：只改简版档位时它不变，于是环径 / 行距 / 内边距**瞬变**
    /// （内容不插值），窗口侧却因为 `configCancellable` 判成形态过渡而播 0.25s ——
    /// 窗口独舞，正是 `EdgeDockController.contentMorphDuration` 注释里禁止的错位。
    ///
    /// 所以 value 必须是"这一帧决定排版的全部输入"：外观（完整/简版）+ 简版档位。
    /// 两者任一变化都触发同一条曲线的内容插值，与窗口侧同判据。
    private struct FormSignature: Equatable {
        let isCompact: Bool
        let compactSize: EdgeDockCompactSize
    }

    private var formSignature: FormSignature {
        FormSignature(
            isCompact: controller.isCompactAppearance,
            compactSize: controller.config.compactSize
        )
    }

    /// 堆叠方向。竖排第 0 行在上，横排第 0 列在左。
    ///
    /// 与 `entries` 的配置顺序合成完整阅读顺序：贴左/右 → **从上往下**；
    /// 贴上/下 → **从左往右**。这一条不是审美选择而是几何约定：
    /// `EdgeDockGeometry.rowCenter` 用同一套锚点把「第 i 个条目」换算成屏幕坐标
    /// 给命中判定用（竖排 `maxY` 起算向下减、横排 `minX` 起算向右加），两边
    /// 必须逐字对应，否则整列会上下翻转、整行会左右翻转，hover 的圆和弹出的
    /// 卡片就对不上。
    ///
    /// 必须与 `EdgeDockGeometry.rowCenter` 的锚点约定逐字对应：视图若用 VStack
    /// 排横边，条目的实际位置就和几何层算的完全不同（而且窗口只有一条窄高，
    /// 行会直接被裁掉）。
    @ViewBuilder
    private func stack<Content: View>(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if controller.config.edge.isVertical {
            VStack(spacing: spacing, content: content)
        } else {
            HStack(spacing: spacing, content: content)
        }
    }

    var body: some View {
        stack(
            spacing: controller.isCompactAppearance
                ? compactMetrics.spacing
                : EdgeDockGeometry.spacing
        ) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(for: entry, index: index)
            }
        }
        .padding(
            controller.isCompactAppearance
                ? compactMetrics.padding
                : EdgeDockGeometry.padding
        )
        // 撑满宿主并朝贴靠边对齐：展开 / 收起变形期间内容小于窗口（展开时窗口
        // 先行扩大、收起时窗口等内容收完再缩小），锚在左上角的话贴右边时背板
        // 会先出现在屏幕内侧、贴边侧露出透明缝。锚到贴靠边后背板始终粘着屏幕
        // 边缘、向屏幕内生长 / 收回。稳态下宿主 == 内容尺寸，这个 frame 不改变
        // 任何东西。
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: alignmentTowardDockedEdge
        )
        // 常驻暗色液态玻璃，**不跟系统外观翻转**：dock 和菜单栏一起长在桌面上，
        // 一天变两次观感没有意义；面板侧另有 vibrantDark + 强制 dark colorScheme
        // 与它配对（见 `ensurePanel`）。
        //
        // **必须排在 `.frame` 之后**：`background` 是按它所装饰视图的边界定尺寸的。
        // 排在 frame 之前它就只包住内容大小，frame 只负责把它摆到位置上——变形期间
        // 窗口跑在内容前面，多出来的那条是透明窗口（`isOpaque = false` + clear 背景），
        // 露出来的会是**桌面**而不是黑边。排在 frame 之后它才跟着窗口一起长。
        .edgeDockDarkGlassBackground(in: EdgeDockTab(edge: controller.config.edge))
        // 完整↔简版的**内容变形**动画：行尺寸、间距、内边距、环直径/弧长都在
        // 同一棵树上插值，与控制器驱动的窗口 frame 动画**同曲线同时长**同步播放
        // ——窗口负责黑条外框与沿边位置（两种形态的帧中心不重合，靠连续动画
        // 平滑衔接），内容负责行 / 环的插值。任一层单独先行都会露出破绽：
        // 只动窗口 = 收起时缩掉的全是透明区域；只动内容 = 结束后窗口必须瞬移。
        //
        // 曲线取 `formMorphControlPoints` 而不是直接写 `.easeOut`：两边的 `easeOut`
        // 本来就是同一条曲线（两个框架各给了一份同值的预设），但"碰巧一致"不是
        // 契约——谁把其中一侧换成别的预设，这里没有任何东西会反对。共用常量之后
        // 同曲线才变成能钉住的事实。控制点见该常量的注释。
        .animation(
            .timingCurve(
                EdgeDockController.formMorphControlPoints.x1,
                EdgeDockController.formMorphControlPoints.y1,
                EdgeDockController.formMorphControlPoints.x2,
                EdgeDockController.formMorphControlPoints.y2,
                duration: EdgeDockController.contentMorphDuration
            ),
            value: formSignature
        )
        .onReceive(state.statusDidChange) { _ in tick &+= 1 }
        .onReceive(state.$healthEvaluationDate) { _ in tick &+= 1 }
    }

    private var alignmentTowardDockedEdge: Alignment {
        switch controller.config.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    private func row(for entry: EdgeDockEntry, index: Int) -> some View {
        VStack(spacing: EdgeDockGeometry.labelSpacing) {
            circle(for: entry)
                // hover 高亮只缩放圆环本身。`scaleEffect` 不参与排版：行框、窗口
                // 尺寸、命中矩形全部不动，放大出的部分落进四周内边距——dock 的
                // 其他行和数值文字都不会跟着动。之前缩放作用在整行、以行中心为锚，
                // 圆会被往数值一侧顶，hover 时整个 dock 看起来在跳。
                //
                // 点击选中的圆保持放大：卡片是钉住的，鼠标移开后若圆缩回原样，
                // 就没有任何线索表明卡片属于哪个圆。
                .scaleEffect(
                    (controller.hoveredIndex == index || controller.selectedIndex == index)
                        ? EdgeDockGeometry.hoverScale
                        : 1
                )
                .animation(.easeOut(duration: 0.12), value: controller.hoveredIndex)
                .animation(.easeOut(duration: 0.12), value: controller.selectedIndex)
            // 简版没有数值文字：移除式切换 + opacity transition，让高度插值期间
            // 文字淡出而不是瞬间消失。
            if !controller.isCompactAppearance {
                quotaLabel(for: entry)
                    .transition(.opacity)
            }
        }
        // 宽高随形态插值（完整 = 圆宽×行高，简版 = 小环一边），收起时行高从
        // `rowHeight`(54) 连续收缩到 `compactDiameter`(7)，dock 看起来是整体缩回去
        // 而不是换了一套内容。**不写死数字**：两个值都由 `EdgeDockGeometry` 推导，
        // 写在这里曾经和实际值对不上过两次（52/50 各一次）。
        .frame(
            width: controller.isCompactAppearance
                ? compactMetrics.diameter
                : EdgeDockGeometry.diameter,
            height: controller.isCompactAppearance
                ? compactMetrics.diameter
                : EdgeDockGeometry.rowHeight
        )
        // 逐行**直报**给控制器，不走 PreferenceKey。
        //
        // `onPreferenceChange` 只在偏好值**发生变化**时回调，而首次布局那一轮
        // 它拿到的是 `defaultValue`（空字典）；行矩形要等排版完成才有值，之后
        // 若没有新的布局轮次就永远不会再补发。实测矩形会一直停在空数组，
        // 命中判定全落空 —— 症状是 hover 和拖拽**同时**失能（接管由命中驱动）。
        // `onAppear` / `onChange` 不挑时机，每次排版变化都到。
        //
        // 量的是**未缩放**的行框（缩放在行内的圆上，且 scaleEffect 本就不参与
        // 排版）：实测矩形恒等于排版矩形，命中判定没有反馈环。
        .background(
            GeometryReader { geo in
                // `.global` 即 NSHostingView 的坐标系，控制器直接拿它换算屏幕坐标，
                // 不需要再假设根视图与窗口左上角对齐。
                let rect = geo.frame(in: .global)
                Color.clear
                    .onAppear { controller.updateMeasuredRowRect(id: entry.id, rect: rect) }
                    .onChange(of: rect) { _, newValue in
                        controller.updateMeasuredRowRect(id: entry.id, rect: newValue)
                    }
            }
        )
    }

    /// 单个 provider 的圆：完整形态 = 双环 + 品牌图标；简版 = 缩到 14pt 的单环。
    ///
    /// 两种形态是**同一棵树的插值**而不是两套分支：外环直径、弧长随
    /// `isCompactAppearance` 连续过渡，内环 / 图标 / 数值淡出，黑条因此从边缘
    /// 长出 / 收回而不是瞬间换内容。简版单环取 5h 有效额度、没有 5h 窗口的退到
    /// 周窗口（与数值文字同一取值口径）。
    private func circle(for entry: EdgeDockEntry) -> some View {
        ZStack {
            ring(
                fraction: controller.isCompactAppearance
                    ? (entry.intervalFraction ?? entry.weeklyFraction)
                    : entry.intervalFraction,
                diameter: controller.isCompactAppearance
                    ? compactMetrics.diameter
                    : EdgeDockGeometry.outerRingDiameter,
                lineWidth: controller.isCompactAppearance
                    ? compactMetrics.ringLineWidth
                    : EdgeDockGeometry.ringLineWidth,
                // 外环读 5h 窗口的色档；简版只有一环，取值口径必须与它的**弧长**
                // 回退一致（没有 5h 窗口时退到周窗口），否则会出现"弧长画的是周
                // 窗口、颜色说的是 5h 窗口"的错配。
                tint: healthTint(
                    for: controller.config.independentRingColors
                        ? (entry.intervalHealth ?? entry.weeklyHealth)
                        : entry.health
                )
            )

            if !controller.isCompactAppearance {
                // 内环（周窗口）
                ring(
                    fraction: entry.weeklyFraction,
                    diameter: EdgeDockGeometry.innerRingDiameter,
                    // 粗外细内：两环同样粗会读成"同一条弧画了两遍"，
                    // 层级消失。取值理由见 `EdgeDockGeometry.innerRingLineWidth`。
                    lineWidth: EdgeDockGeometry.innerRingLineWidth,
                    tint: healthTint(
                        for: controller.config.independentRingColors
                            ? entry.weeklyHealth
                            : entry.health
                    )
                )
                .transition(.opacity)

                // 中心品牌图标。尺寸**传给** `BrandLogoView` 而不是在外面套
                // `.frame(width: 6, height: 6)`：外层 frame 不会缩放一个自带固定
                // frame 的子视图，只会把 18pt 的图居中摆在 6pt 的框里（不裁剪），
                // 于是图标按 18pt 画出来、正好压在内环描边上。
                BrandLogoView(kind: entry.kind, size: EdgeDockGeometry.iconSize)
                    .transition(.opacity)
            }
        }
        .frame(
            width: controller.isCompactAppearance
                ? compactMetrics.diameter
                : EdgeDockGeometry.diameter,
            height: controller.isCompactAppearance
                ? compactMetrics.diameter
                : EdgeDockGeometry.diameter
        )
        // 测量各 provider 外圈几何矩形，供精确的圆形区域命中测试使用
        .background(
            GeometryReader { geo in
                let rect = geo.frame(in: .global)
                Color.clear
                    .onAppear { controller.updateMeasuredCircleRect(id: entry.id, rect: rect) }
                    .onChange(of: rect) { _, newValue in
                        controller.updateMeasuredCircleRect(id: entry.id, rect: newValue)
                    }
            }
        )
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(accessibilityValue(for: entry))
    }

    /// 圆环下方常驻的额度数值：优先 5h 有效额度，没有就退到周窗口，都没有显示 `—`。
    ///
    /// 常驻数字是边缘窗不悬停时的唯一可读信息，所以优先给 5h 有效额度——它变化最快，
    /// 才是"现在还能不能干活"的直接答案。始终单数值：原始 5h 的对照只出现在
    /// hover 文案里（见 `caption(for:)`）。
    private func quotaLabel(for entry: EdgeDockEntry) -> some View {
        Text(labelText(for: entry))
            // 字号取 `labelFontSize`：行高 `labelHeight` 就是从它推导的，两处
            // 各写一个 10 的话，改了字号忘了改行高（或反过来）就会让数值在
            // 固定行框里溢出。
            .font(.system(size: EdgeDockGeometry.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            // dock 内容被强制在 dark colorScheme 下渲染（见 ensurePanel），
            // `primary` 因此恒为浅色；语义色而不是写死白色，只是不再需要那个
            // "因为不随外观变化所以写死"的特例。
            .foregroundStyle(Color.primary.opacity(0.9))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func labelText(for entry: EdgeDockEntry) -> String {
        guard let fraction = entry.intervalFraction ?? entry.weeklyFraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// 单个环：底槽 + 顺时针收缩的健康色弧。
    ///
    /// **底槽永远画**，不受数据有无影响：还在加载、首次拉取、或该 provider 根本没有
    /// 额度窗口时，槽是"这里有一个环，只是读不到数"的唯一提示。槽和弧是两次独立
    /// 绘制，不能因为 `fraction == nil` 就把整个环连槽一起跳过。
    ///
    /// 底槽颜色见 `EdgeDockTheme.ringTrack`：dock 强制暗色，`Color.primary` 恒为
    /// 浅色，所以底槽在深色玻璃上始终看得见。底槽看不见会被读成"环画断了"，
    /// 那是**错的**数据，不只是难看的界面。
    private func ring(
        fraction: Double?,
        diameter: CGFloat,
        lineWidth: CGFloat = EdgeDockGeometry.ringLineWidth,
        tint: Color
    ) -> some View {
        ZStack {
            Circle()
                .stroke(EdgeDockTheme.ringTrack, lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            if let range = EdgeDockGeometry.arcTrimRange(fraction: fraction) {
                Circle()
                    .trim(from: range.lowerBound, to: range.upperBound)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    // MARK: - 取值

    /// 某一档健康度 → 环色。
    ///
    /// 传 `HealthLevel?` 而不是 `EdgeDockEntry`：内外环独立取色时两个环问的是
    /// **不同**的档位（5h / 周），把它们合成一个参数就等于把独立取色又合回去了。
    /// nil 落回中性灰而不是随便取一档：灰 ≠ 绿 ≠ 红，"读不到"必须读成"读不到"。
    private func healthTint(for level: HealthLevel?) -> Color {
        guard let color = healthColors.color(for: level) else {
            return Color(nsColor: .tertiaryLabelColor)
        }
        return Color(nsColor: color)
    }

    /// 辅助功能朗读文案（`accessibilityValue`）：`5h 段 · 周 段 · 健康档`。
    ///
    /// 5h 段在**周折算构成瓶颈**（有效额度 < 原始 5h）时并排显示两个数
    /// （`5h 90%(30%有效)`，见 `EdgeDockProjection.intervalCaption`）：外环读的是
    /// 有效额度，只读一个数会让人误以为 5h 真的只剩这么多，补上原始值才能听出
    /// 差额来自周瓶颈、不是 5h 本身见底。曾经同时喂 `.help(...)` tooltip，但
    /// 穿透态下几乎无法触发（详情 popover 又更快更醒目），tooltip 已移除；
    /// 文案保留给 VoiceOver，视觉侧无感知。常驻数值（`quotaLabel`）不受影响，
    /// 仍然只显示有效额度。
    private func caption(for entry: EdgeDockEntry) -> String {
        guard entry.hasAnyQuotaWindow else { return healthText(for: entry) }
        var parts: [String] = []
        if let interval = entry.intervalFraction {
            parts.append(EdgeDockProjection.intervalCaption(
                effective: interval,
                raw: entry.rawIntervalFraction
            ))
        }
        if let weekly = entry.weeklyFraction {
            parts.append("周 \(percentText(weekly))")
        }
        parts.append(healthText(for: entry))
        return parts.joined(separator: " · ")
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func healthText(for entry: EdgeDockEntry) -> String {
        switch entry.health {
        case .healthy:  return "正常"
        case .warning:  return "预警"
        case .critical: return "告急"
        case nil:       return "无数据"
        }
    }

    private func accessibilityValue(for entry: EdgeDockEntry) -> String {
        caption(for: entry)
    }
}

import CoreGraphics

/// 跨层共享的排版常量。
///
/// 放在 Services 而不是某个 View 文件里，是因为 **Services 侧要读它们**：
/// `EdgeDockTheme.popoverWidth`（边缘窗的纯几何推导）由
/// `SevenDayUsageChartMetrics.pricedWidth` + 下面两个内边距相加得出。声明留在
/// Views 时，Services 就得反向依赖视图文件；这两个方向都合法之后，常量才有唯一的
/// 归属地，改一处两边一起变。
///
/// 只放**纯字面量排版值**：这里没有任何状态、也没有任何 SwiftUI 类型。
/// 纯 CGFloat 常量没有隔离的必要（放在这里也不再需要 `nonisolated` 标注——
/// 声明方本来就不是 View / NSViewRepresentable，不带 actor 推断）。
enum LayoutMetrics {
    /// 主菜单卡片列的水平内边距。边缘状态窗的 popover 复用同一数值，两边的卡片宽度
    /// 才能逐像素一致（见 `EdgeDockTheme.popoverPadding`）。
    static let cardColumnHorizontalPadding: CGFloat = 12

    /// Provider 卡片内容层四周的内边距。`EdgeDockTheme.popoverWidth` 推导宽度时
    /// 要加上这一层的两侧（见那里 420 → 444 → 468 的链路），因此同样不能只留在
    /// `ProviderCardView` 里。
    static let cardContentPadding: CGFloat = 12
}

/// 7 天 token 图表的固定宽度常量。
///
/// 这是浮层宽度的**推导源头**：dock popover 与主菜单 hover 浮层都以这里为基准
/// 算自己的宽度（见 `EdgeDockTheme.popoverWidth` / `HoverPanelController`）。
/// 图表 frame 装不下柱区时不会报错——柱只是安静地溢出 frame、被浮层边缘裁掉，
/// 表现为"7 天的横向展示缺了首尾两天"。
///
/// 与 `LayoutMetrics` 同理：Services 的宽度推导要读它，声明在 Views 会让
/// Services 反向依赖视图文件。
enum SevenDayUsageChartMetrics {
    /// 柱区自然宽度：7 根柱 × 55pt + 6 个 5pt 间距 = 415。图表 frame 的下限。
    static let barsWidth: CGFloat = 55 * 7 + 5 * 6
    /// 带价格列时的图表宽度。表格（34+48+58×4+62 + 间距 18 ≈ 394）比柱区窄，
    /// 仍以柱区为下限再留一点余量。
    static let pricedWidth: CGFloat = 420

    /// `.expanded` 模式（Provider 详情独立窗口）7 天历史表格的各列下限宽度。
    ///
    /// 详情窗口里这些列会以 `minWidth` + `maxWidth: .infinity` 弹性填满可用宽度，
    /// 这里的数值是**缩列时的下限**；表格总宽的下限由 `expandedTableWidth` 派生，
    /// `ProviderDetailWindowView.minimumWindowWidth` 再据此推导窗口最小宽。
    static let expandedDateColumnWidth: CGFloat = 42
    static let expandedRTColumnWidth: CGFloat = 66
    static let expandedBucketColumnWidth: CGFloat = 56
    static let expandedDynamicColumnWidth: CGFloat = 74
    static let expandedTableSpacing: CGFloat = 10

    /// `.expanded` 表格的总宽下限：日期列 42 + R/T 66 + 分桶列 56×4 + 动态列 74
    /// + 间距 10×6 = 466。写成表达式便于与上面各列逐项核对。
    static let expandedTableWidth: CGFloat = 42 + 66 + 56 * 4 + 74 + 10 * 6
}

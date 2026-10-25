import SwiftUI
import AppKit

/// scope 切换控件的两种形态。
///
/// 分界是**选项总数**（全局 + 本机 + 远端节点）≤ 4 还是 > 4：
/// - ≤4：一屏能放下，分段控件一步切换，不用多点一次；
/// - >4：分段控件挤不下节点名（且分段没有宽度预算，节点名一长就被截），
///   改用下拉。
enum FleetScopeControlStyle: Equatable {
    /// 分段控件（`Picker` + `.segmented`）。
    case segmented
    /// label + 行内 ellipsis 标记的下拉（`FleetScopeMenu`）。
    case dropdown

    /// 按选项总数选形态：≤4 分段，>4 下拉。
    ///
    /// `optionCount` = 全局 + 本机 + 远端节点数（宿主传入 `choices.count + 2`）。
    static func preferred(optionCount: Int) -> FleetScopeControlStyle {
        optionCount <= 4 ? .segmented : .dropdown
    }

    /// 按远端节点列表选形态：`choices` 只含远端节点，全局 + 本机另算两项。
    static func preferred(choices: [FleetNodeChoice]) -> FleetScopeControlStyle {
        preferred(optionCount: choices.count + 2)
    }
}

/// scope 切换控件：**按选项数在分段控件与「label + ellipsis」下拉之间分叉**。
///
/// 用法：
/// - dock 详情浮层的 provider 卡（`ProviderCardView`）；
/// - 菜单面板的内容区（`HarnessUsageMenuView`，与菜单标题栏共用同一份 scope）。
///
/// 两种形态的**位置**由宿主决定（位置不能随选项数变）：
/// - **分段形态**（≤4 项）：宿主给它一整行，宽度与卡片一致（见
///   `ProviderCardView.scopeRow` / `HarnessUsageMenuView.scopeRow`）。
/// - **下拉形态**（>4 项）：宿主把它放进标题栏右侧（菜单面板标题栏的右组、
///   dock 卡片头的右侧），紧凑显示。
struct FleetScopeSwitcher: View {
    let scope: FleetScope
    /// 远端节点选项（本机由「本机」项承担，这里只列远端）。
    let choices: [FleetNodeChoice]
    /// 选中后回调。
    let onSelect: (FleetScope) -> Void
    /// 形态。nil = 按选项数自动选（≤4 分段，>4 下拉）。
    var style: FleetScopeControlStyle?

    private var resolvedStyle: FleetScopeControlStyle {
        style ?? FleetScopeControlStyle.preferred(choices: choices)
    }

    var body: some View {
        switch resolvedStyle {
        case .segmented:
            segmentedControl
        case .dropdown:
            FleetScopeMenu(scope: scope, choices: choices, onSelect: onSelect)
        }
    }

    /// 分段形态：全局 / 本机 / 各远端节点，一眼看到全部选项、一步切换。
    ///
    /// 节点名按原样进分段（**不加**「（离线）」后缀）：分段控件没有宽度预算，
    /// 加了后缀节点名会被挤到截断。陈旧与否在这个形态里看不出来——这是分段
    /// 形态的固有代价，选项一多就会换成下拉形态（那里带后缀）。
    ///
    /// **不加 `.fixedSize()`**：宿主要它撑满整行（宽度与卡片一致），fixedSize
    /// 会把它钉在自然宽度上，段落就短一截。
    private var segmentedControl: some View {
        Picker(selection: Binding(
            get: { scope },
            set: { onSelect($0) }
        )) {
            Text("全局").tag(FleetScope.fleet)
            Text("本机").tag(FleetScope.local)
            ForEach(choices) { choice in
                Text(choice.name).tag(FleetScope.node(choice.id))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
    }
}

/// fleet scope 的**下拉**形态：**当前范围文字 + 行内 ellipsis 标记**，点开下拉选节点。
///
/// 宿主：
/// - 菜单面板标题栏（`MenuContentView`）——scope 组与刷新按钮同处右端；
/// - dock 详情浮层的 provider 卡头（`ProviderCardView`）——选项 >4 时。
///
/// 三个 macOS 平台怪癖决定了实现形状（都是实测结论，勿轻易改回）：
/// 1. **ellipsis 必须是行内图**（`Text` 字符串里的图片附件），不能是独立的
///    `Image`：SwiftUI 把 `Menu` 的 label 映射成 AppKit `NSButton` 的
///    image + title，label 里的独立 `Image` 会被提到**最前面**（文字反而跑到
///    标记右边）。行内图是 title 字符串的一部分，顺序天然正确。
/// 2. **宽度限制必须做在字符串层**（`truncated(_:maxWidth:)`）：`Menu` label
///    忽略内部的宽度限制；限宽 frame 挂到 `Menu` 外面又会被 HStack 当成弹性
///    视图吃掉剩余空间（文案短时反而在文字和标记之间拉出一大段空白）。
/// 3. **必须 `.fixedSize()`**：否则 SwiftUI 把按钮撑到**最宽的那个菜单项**
///    （节点名 + 「（离线）」，实测 109pt），控件宽度随节点名漂移。
struct FleetScopeMenu: View {
    /// 「范围文字 + ellipsis 标记」整组的最大宽度（磅）。超出后范围文字省略号
    /// 截断，标记始终保留（节点名可以是任意长度的主机名）。
    static let maxLabelWidth: CGFloat = 120

    /// 文字尾部给 ellipsis 标记留的空位（磅）：一个空格 + 行内图标的宽度。
    /// 文字按 `maxLabelWidth - glyphReserve` 截断，加上标记之后整组正好
    /// 不超过 `maxLabelWidth`。
    static let glyphReserve: CGFloat = 16

    /// 当前 scope。
    let scope: FleetScope
    /// 远端节点选项（本机由「本机」项承担，这里只列远端）。
    let choices: [FleetNodeChoice]
    /// 选中后回调。
    let onSelect: (FleetScope) -> Void

    var body: some View {
        Menu {
            Button("全局") { onSelect(.fleet) }
            Button("本机") { onSelect(.local) }
            Section("节点") {
                ForEach(choices) { choice in
                    Button {
                        onSelect(.node(choice.id))
                    } label: {
                        Text(choice.name + (choice.stale ? "（离线）" : ""))
                    }
                }
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 按钮宽度必须贴着 label：不加这一行，SwiftUI 会把 Menu 按钮撑到**最宽
        // 的那个菜单项**（节点名 + 「（离线）」，实测 109pt），scope 组宽度就
        // 随节点名漂移，旁边的控件留白跟着变。
        .fixedSize()
    }

    /// label 内容：范围文字（按上限截断）+ 行内 ellipsis 标记。
    private var label: some View {
        let text = FleetScopeMenu.truncated(
            FleetScopeMenu.labelText(scope, choices: choices),
            maxWidth: FleetScopeMenu.maxLabelWidth - FleetScopeMenu.glyphReserve
        )
        return Text("\(text) \(Image(systemName: "ellipsis"))")
            .font(MenuTypography.headerAction)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// 当前 scope 的文案。全局 / 本机是固定词；节点取选项里的名字（找不到时
    /// 退化成「节点」——快照刷新后节点可能已经不在列表里）。
    static func labelText(_ scope: FleetScope, choices: [FleetNodeChoice]) -> String {
        switch scope {
        case .fleet: return "全局"
        case .local: return "本机"
        case .node(let id):
            return choices.first { $0.id == id }?.name ?? "节点"
        }
    }

    /// 按可用宽度截断：超出就从尾部截并补省略号。
    ///
    /// 字体与 `MenuTypography.headerAction` 对齐（11pt medium），量出来的宽度
    /// 就是渲染宽度；`…` 用与系统截断一致的省略号字符。
    static func truncated(_ text: String, maxWidth: CGFloat) -> String {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ candidate: String) -> CGFloat {
            (candidate as NSString).size(withAttributes: attributes).width
        }
        guard width(text) > maxWidth else { return text }
        var head = text
        while !head.isEmpty {
            head = String(head.dropLast())
            let truncated = head + "…"
            if width(truncated) <= maxWidth { return truncated }
        }
        return "…"
    }
}

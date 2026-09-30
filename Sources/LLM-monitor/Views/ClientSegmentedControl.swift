import SwiftUI
import AppKit

/// 客户端切换用的原生 `NSSegmentedControl`。
///
/// 为什么不用 SwiftUI 的 `Picker(...).pickerStyle(.segmented)`：
///
/// 1. **分段 Picker 不滚动**。客户端数量会随版本增加（现在 6 个），SwiftUI 会把
///    宽出容器的那部分按比例压回去，"MiniMax Code" 直接截成省略号。这里按每段
///    内容的**测量宽度**写死段宽（`width(forSegment:)`），控件整体变宽，交给外层
///    横向滚动——和原来那排胶囊的行为一致，只是换成了系统控件。
/// 2. 分段 Picker 只能渲染 `Text`，计数徽标没法用小一号字和次级色。
///
/// 代价：**图标没了**。`NSSegmentedControl` 既没有富文本标签 API（`setLabel` 只收
/// `String`），也不能同时给图标和文字（`setImage` 会把标签整个替掉）。想要
/// "图标 + 名称 + 计数"只能自己把标签渲染成图片塞进 `setImage`，那样就得放弃模板
/// 染色（选中态/深浅色全得自己画），得不偿失。客户端名本身已经足够区分——旁边
/// 还有 5 个并列的名字——所以只留文字，计数跟在名字后面。全称放到 tooltip 里。
struct ClientSegmentedControl: NSViewRepresentable {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        /// 该客户端下有 Token 活动的 Provider 数；0 表示不显示计数。
        let badge: Int
        /// tooltip 里的补充说明（例如"本地会话与 token 用量"）。
        let subtitle: String

        init(id: String, title: String, badge: Int, subtitle: String = "") {
            self.id = id
            self.title = title
            self.badge = badge
            self.subtitle = subtitle
        }

        /// 段标签：`NSSegmentedControl` 只吃纯文本，计数只能跟在名字后面。
        /// 计数用括号包起来：纯空格分隔时"DSH 2"分不清是 Provider 数还是版本号，
        /// 括号是列表里最省位置、又不会被误读成名字一部分的写法。
        var label: String { badge > 0 ? "\(title) (\(badge))" : title }

        var toolTip: String {
            guard badge > 0 else { return subtitle }
            return subtitle.isEmpty
                ? "\(title) · \(badge) 个 Provider"
                : "\(title) · \(badge) 个 Provider · \(subtitle)"
        }
    }

    let items: [Item]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, segmentIDs: items.map(\.id))
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .texturedRounded
        control.trackingMode = .selectOne
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.handleChange(_:))
        context.coordinator.control = control
        Self.applySegments(items, to: control)
        Self.syncSelection(selection, items: items, onto: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        // selection 是 @Binding：父视图改了值（例如 onAppear 纠正一个已不存在的
        // 客户端）也要同步到控件上。用户侧的回弹由 Coordinator 负责，只在值真的
        // 变了时才写回。
        context.coordinator.selection = $selection
        context.coordinator.segmentIDs = items.map(\.id)
        Self.applySegments(items, to: control)
        Self.syncSelection(selection, items: items, onto: control)
    }

    /// 段标签的左右内边距（两侧合计）。
    ///
    /// 标定方式：单段 `NSSegmentedControl` 塞一个标签后 `sizeToFit()`，减去
    /// 同字体下的文字宽度。DSH 24.35 / Codex 24.42 / Antigravity 24.23 /
    /// MiniMax Code 24.14 / "MiniMax Code 12" 24.33——五个长度跨 3 倍的标签都落在
    /// 24.1~24.4，是个与文字长度无关的常数，取 24.5 留半个点的余量。
    static let segmentHorizontalPadding: CGFloat = 24.5

    /// 一段该有多宽：文字宽度 + 内边距。
    ///
    /// **不能**用 `NSSegmentedControl.width(forSegment:)`：它对还没进窗口的控件一律
    /// 返回 0（裸控件、设了 segmentStyle、sizeToFit 之后、给了 frame 之后都试过，
    /// 全是 0；只有控件已经在窗口里被布局过一次才给真值）。而把 0 写进
    /// `setWidth(_:forSegment:)` 会把所有段宽压成 0，整个切换条消失。冷启动时
    /// `makeNSView` 一定早于进窗口，所以那条路本身就是个定时炸弹。自己量文字
    /// 宽度则不依赖控件是否已经布局过——`NSString.size(withAttributes:)` 在无窗口
    /// 时照样给准确值。
    static func segmentWidth(for label: String, font: NSFont) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + segmentHorizontalPadding
    }

    /// 把 items 铺进控件：段数、标签、tooltip、段宽。
    ///
    /// 拆成无状态静态方法而不是留在 `updateNSView` 里，是为了能被测试直接驱动——
    /// 这段路的两个坑（空列表、段数变化后旧段宽残留）都在这里。
    @MainActor
    static func applySegments(_ items: [Item], to control: NSSegmentedControl) {
        // 空数组时 NSSegmentedControl 不接受 segmentCount = 0（抛 NSException，
        // 不是 Swift 错误，catch 不住，只会让进程崩），所以留一个空段。
        let count = max(items.count, 1)
        if control.segmentCount != count {
            control.segmentCount = count
            // 段数变了，上一轮写死的段宽作废：先清零，下面按内容重新测量。
            for index in 0..<count { control.setWidth(0, forSegment: index) }
        }
        for (index, item) in items.enumerated() {
            control.setLabel(item.label, forSegment: index)
            control.setToolTip(item.toolTip, forSegment: index)
        }
        // 按内容测量每段宽度并写死，别让控件放不下时被压缩、标签截成省略号。
        // 只定各段宽度、不去钉整幅控件的宽度（`setWidth(_:forSegment: -1)`）：
        // 控件 frame 本来就是各段宽度之和，再钉一遍容易和实际差一两个像素、
        // 把最后一段切掉一点。
        // `control.font` 在没进窗口时也已经是系统 13pt（NSControl 的默认值），
        // 真为 nil 才退回系统字体——量不出来总比量错强。
        let font = control.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for index in 0..<count {
            control.setWidth(items.indices.contains(index)
                             ? segmentWidth(for: items[index].label, font: font)
                             : 0, forSegment: index)
        }
    }

    /// 外部改了 selection 时把选中段挪过去；items 里找不到这个 id 就保持控件原样
    /// （不擅自选一个段——那会让 UI 显示的选中项和 `selectedClientID` 悄悄分叉）。
    @MainActor
    static func syncSelection(_ selection: String, items: [Item], onto control: NSSegmentedControl) {
        guard let index = items.firstIndex(where: { $0.id == selection }),
              control.selectedSegment != index
        else { return }
        control.selectedSegment = index
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        /// 与 `items` 同序的客户端 id，供 `handleChange` 按选中下标取回。
        var segmentIDs: [String]
        weak var control: NSSegmentedControl?

        init(selection: Binding<String>, segmentIDs: [String]) {
            self.selection = selection
            self.segmentIDs = segmentIDs
        }

        @objc func handleChange(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0,
                  sender.selectedSegment < segmentIDs.count
            else { return }
            let id = segmentIDs[sender.selectedSegment]
            guard id != selection.wrappedValue else { return }
            selection.wrappedValue = id
        }
    }
}

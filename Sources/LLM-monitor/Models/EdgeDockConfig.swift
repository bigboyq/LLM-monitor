import Foundation

/// 边缘状态窗贴靠的屏幕边。
enum DockEdge: String, Codable, CaseIterable, Sendable, Identifiable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .right:  return "右侧"
        case .left:   return "左侧"
        case .top:    return "顶部"
        case .bottom: return "底部"
        }
    }

    /// 该边是竖直边（圆环竖排）还是水平边（圆环横排）。
    var isVertical: Bool {
        self == .left || self == .right
    }
}

/// 边缘状态窗的用户配置。落盘在 `config.json` 的顶层 `edgeDock`。
struct EdgeDockConfig: Codable, Equatable, Sendable {
    /// 总开关。默认**关闭** —— 新窗口属于主动开启的额外面板，不该在升级后自己冒出来。
    var enabled: Bool

    /// 贴靠边。默认右侧。
    ///
    /// 设置页**没有**这个选项——dock 可以直接拖到任意边缘，拖动时写入的就是它。
    /// 摆一个 Picker 在那里只会让人以为"拖了会被这个下拉框改回去"。
    var edge: DockEdge

    /// 沿贴靠边方向的归一化位置，`0...1`（0 = 该边起点，1 = 该边终点）。
    ///
    /// 刻意存**比例**而不是绝对点坐标：换显示器 / 改分辨率 / macOS Dock 显隐都会改变
    /// `visibleFrame`，存绝对坐标会让窗口直接掉到屏幕外且再也无法拖回来。
    var offset: Double

    /// 自动隐藏模式：平时收起为紧贴边缘的**简版**（只有 5h 单环小圆，无数字无图标），
    /// 鼠标靠近才展开为完整 dock。默认关闭 = 常驻完整形态。
    var autoHideMode: Bool

    /// 前台 App 进入全屏时隐藏 dock。默认 **true** = 维持既有行为。
    ///
    /// 默认给 true 而不是 false：这是一个"从没有这个开关"改成"有开关"的功能，
    /// 默认 false 等于**升级后所有已开启 dock 的用户立刻在全屏里多出一个窗口**。
    /// 那不是新功能，那是行为突变。
    var hideInFullscreen: Bool

    init(
        enabled: Bool,
        edge: DockEdge,
        offset: Double,
        autoHideMode: Bool = false,
        hideInFullscreen: Bool = true
    ) {
        self.enabled = enabled
        self.edge = edge
        self.offset = offset
        self.autoHideMode = autoHideMode
        self.hideInFullscreen = hideInFullscreen
    }

    enum CodingKeys: String, CodingKey {
        case enabled, edge, offset, autoHideMode, hideInFullscreen
    }

    /// 自定义 decode 只为一件事：`autoHideMode` 是后加的字段，旧 config.json 里没有，
    /// 合成版 Codable 会因此**整体解码失败** —— 而外层 `ConfigStore` 对 edgeDock 用的是
    /// `try?`（坏值按没配过处理），失败意味着用户已经开启的 dock 被静默重置回默认关闭。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        edge = try container.decode(DockEdge.self, forKey: .edge)
        offset = try container.decode(Double.self, forKey: .offset)
        autoHideMode = try container.decodeIfPresent(Bool.self, forKey: .autoHideMode) ?? false
        // 同理：后加字段，缺省 true 保持旧配置的行为不变。
        hideInFullscreen = try container.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? true
    }

    static let `default` = EdgeDockConfig(enabled: false, edge: .right, offset: 0.5)

    /// 全屏时是否应该隐藏。
    ///
    /// 放在配置上而不是控制器里，是因为这是**纯策略**：不碰窗口、不碰 AppKit 状态。
    /// 控制器里那个私有 `isHiddenByFullscreen` 混着整套 reconcile 逻辑，没法直接测，
    /// 而"关掉这个开关之后全屏到底还隐不隐藏"恰恰是最该被钉住的行为。
    ///
    /// 参数名是 `isFullscreenSpace` 而不是"前台 App 全屏"：判据问的是**目标屏当前
    /// Space 上有没有全屏窗口**，与前台 App 无关（滑到非前台 App 的全屏 Space 也要
    /// 算全屏）。名字写成前台会让下一个读代码的人把进程过滤加回去。
    func hidesInFullscreen(isFullscreenSpace: Bool) -> Bool {
        hideInFullscreen && isFullscreenSpace
    }

    /// 把越界 / NaN 的手改值拉回合法区间。手改 config.json 写 `"offset": 42` 不该
    /// 产生一个永远画在屏幕外的窗口。
    var normalized: EdgeDockConfig {
        EdgeDockConfig(
            enabled: enabled,
            edge: edge,
            offset: offset.isFinite ? min(max(offset, 0), 1) : 0.5,
            autoHideMode: autoHideMode,
            hideInFullscreen: hideInFullscreen
        )
    }
}

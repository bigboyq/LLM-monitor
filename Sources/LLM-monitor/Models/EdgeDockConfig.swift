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
    var edge: DockEdge

    /// 沿贴靠边方向的归一化位置，`0...1`（0 = 该边起点，1 = 该边终点）。
    ///
    /// 刻意存**比例**而不是绝对点坐标：换显示器 / 改分辨率 / macOS Dock 显隐都会改变
    /// `visibleFrame`，存绝对坐标会让窗口直接掉到屏幕外且再也无法拖回来。
    var offset: Double

    /// 自动隐藏模式：平时收起为紧贴边缘的**简版**（只有 5h 单环小圆，无数字无图标），
    /// 鼠标靠近才展开为完整 dock。默认关闭 = 常驻完整形态。
    var autoHideMode: Bool

    init(enabled: Bool, edge: DockEdge, offset: Double, autoHideMode: Bool = false) {
        self.enabled = enabled
        self.edge = edge
        self.offset = offset
        self.autoHideMode = autoHideMode
    }

    enum CodingKeys: String, CodingKey {
        case enabled, edge, offset, autoHideMode
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
    }

    static let `default` = EdgeDockConfig(enabled: false, edge: .right, offset: 0.5)

    /// 把越界 / NaN 的手改值拉回合法区间。手改 config.json 写 `"offset": 42` 不该
    /// 产生一个永远画在屏幕外的窗口。
    var normalized: EdgeDockConfig {
        EdgeDockConfig(
            enabled: enabled,
            edge: edge,
            offset: offset.isFinite ? min(max(offset, 0), 1) : 0.5,
            autoHideMode: autoHideMode
        )
    }
}

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

/// 边缘状态窗的**形态**。设置页里是一个 picker 的四个选项，不是"总开关 +
/// 自动隐藏模式"两个布尔。
///
/// 两个布尔能拼出四种组合，其中一种（关掉总开关时的自动隐藏）根本没有意义；
/// 而两个真实形态"常驻完整"与"常驻小圆环"也没有自己的名字，用户看到
/// 「自动隐藏模式（收起为小圆环）」只能反推出"关掉它就常驻"。四选一之后每个
/// 形态都有名字，设置项与屏幕上的样子一一对应，切换也不再有"两个开关同时
/// 管一件事"的中间态。
enum EdgeDockMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 不显示。**保留在 picker 里**而不是"用一个开关代替它"：关掉 dock 是
    /// 一次明确的决定，混在一个开关里关掉之后就看不出"是没开还是被全屏挡了"。
    case hidden

    /// 常驻完整状态窗：双环 + 品牌图标 + 额度数值。
    case statusWindow

    /// 常驻小圆环：只有 5h 单环小圆（没有 5h 窗口的退到周窗口），无数字无图标。
    /// **不随鼠标展开**——鼠标停在上面只有该 provider 的详情卡片，不长出完整形态。
    case compactRings

    /// 平时收起为小圆环，鼠标靠近才展开为完整状态窗。默认。
    case autoHideWindow

    /// 设置页的默认值。
    ///
    /// 给 `.autoHideWindow` 而不是"什么都不显示"：完整功能默认开着，但屏幕上
    /// 默认只占边缘一条 7pt 的小环列，鼠标靠近才长出来。这是唯一一种"装了就有
    /// 用、但完全不打扰"的形态——真不想要的人去 picker 里选「无」，而不是靠一个
    /// 默认关闭的开关把功能整个藏起来。
    static let `default` = EdgeDockMode.autoHideWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden:         return "无"
        case .statusWindow:   return "状态窗"
        case .compactRings:   return "小圆环"
        case .autoHideWindow: return "状态窗（自动隐藏）"
        }
    }

    /// picker 选中项下方的一行说明：每种形态在屏幕上到底长什么样。
    var summary: String {
        switch self {
        case .hidden:
            return "不显示边缘状态窗。"
        case .statusWindow:
            return "常驻完整圆环窗：双环、品牌图标与额度数值一直显示，悬停出详情卡片。"
        case .compactRings:
            return "常驻小圆环：只有一列 5h 单环小圆，无图标与数值；悬停某个圆仍会弹出该 Provider 的详情卡片，但不会展开成完整形态。"
        case .autoHideWindow:
            return "平时收起为小圆环，鼠标靠近时展开为完整圆环窗，移开后延时收起。"
        }
    }

    /// 是否显示 dock。除 `.hidden` 外都显示。
    var isVisible: Bool { self != .hidden }

    /// 鼠标靠近时是否把 dock 展开成完整形态。
    ///
    /// 只有「状态窗（自动隐藏）」有这个行为：简版的圆只有 7pt，"dock 长出来"
    /// 本身就是对靠近动作的回应，逐行命中在这个尺寸下只会抖。
    ///
    /// 「小圆环」刻意**不**展开——它要的就是屏幕上永远只有那一列小环；一个会
    /// 长的东西等于把用户选的形态换掉了。它仍然逐行 hover 出详情卡片（见
    /// `EdgeDockController.probeMouse`），但 dock 本身的形态不变。
    var expandsOnProximity: Bool { self == .autoHideWindow }

    /// 静置（鼠标不在）时是否保持完整形态。
    var staysFullWhenIdle: Bool { self == .statusWindow }

    /// 这个形态**会不会**以简版小圆环出现。
    ///
    /// 「小圆环」恒为简版；「状态窗（自动隐藏）」收起时是简版；「状态窗」恒完整；
    /// 「无」根本不显示。设置页据此禁用"小圆环尺寸"——那一条只被简版消费，
    /// 在恒完整或根本不显示的形态下改了屏幕上的像素一动不动。
    var usesCompactAppearance: Bool { isVisible && !staysFullWhenIdle }
}

/// 收起形态（简版小圆环）的尺寸档位。
///
/// 三档对应三组环径 / 线宽 / 间距 / 内边距（见 `EdgeDockGeometry.compactMetrics`）。
/// 做成**枚举**而不是一个数字滑块：这几个量之间有硬约束（线宽不能吃掉环心、
/// 判定半径不能低于可用性下限、贴边厚度必须小于完整版），滑块能滑出的组合里
/// 大部分是不合法的，而三档是全部算过、都成立的。
enum EdgeDockCompactSize: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 环径 7 / 线宽 2.5 / 间距 8 / 内边距 7 → 贴边厚度 21、行距 15。
    case small
    /// 环径 11 / 线宽 3.5 / 间距 10 / 内边距 10 → 贴边厚度 31、行距 21。
    case medium
    /// 环径 14 / 线宽 4 / 间距 12 / 内边距 12 → 贴边厚度 38、行距 26。
    case large

    /// 默认给小的那档：升级前屏幕上的简版就是这一组尺寸，缺省改成更大的会让所有
    /// 开着 dock 的用户一升级就看到黑条变粗。
    static let `default`: EdgeDockCompactSize = .small

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:  return "小"
        case .medium: return "中"
        case .large:  return "大"
        }
    }
}

/// 边缘状态窗的用户配置。落盘在 `config.json` 的顶层 `edgeDock`。
struct EdgeDockConfig: Codable, Equatable, Sendable {
    /// 显示形态（四选一）。默认 `EdgeDockMode.default`。
    var mode: EdgeDockMode

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

    /// 停在**哪块屏**上：那块屏的 display UUID（见 `EdgeDockDisplay`）。
    ///
    /// nil = 没指定，dock 跟随"当前所在屏"（未显示时是主屏）——这是本字段加入之前
    /// 的全部行为，保留为默认值是升级不改动的保证。
    ///
    /// 存 UUID 而不是下标 / 几何位置：下标跟屏幕排列走、几何位置在同分辨率双屏上
    /// 压根区分不开，两样都会让 dock 在用户没动它的时候跑掉。
    var screenUUID: String?

    /// 前台 App 进入全屏时隐藏 dock。默认 **true** = 维持既有行为。
    ///
    /// 独立于 `mode`：它是"什么时候让路"，不是"dock 长什么样"，两者正交——
    /// 所以即便形态选了「无」，这个开关也仍然有意义的读法（选了任何一种形态都受它管）。
    ///
    /// 默认给 true 而不是 false：这是一个"从没有这个开关"改成"有开关"的功能，
    /// 默认 false 等于**升级后所有已开启 dock 的用户立刻在全屏里多出一个窗口**。
    /// 那不是新功能，那是行为突变。
    var hideInFullscreen: Bool

    /// 收起形态（简版小圆环）的尺寸档位。默认 `EdgeDockCompactSize.default`（小）。
    ///
    /// 只对**简版**有消费者：形态选「小圆环」，或「状态窗（自动隐藏）」处于收起态。
    /// 完整形态的外环直径 / 内边距不读它，所以设了档位而不选那两种形态时，
    /// 设置页里的这一行会跟着全屏开关一起禁用。
    var compactSize: EdgeDockCompactSize

    /// 展开形态是否让**外环与内环各自取色**：开 = 外环按 5 小时窗口、内环按周窗口
    /// 各自的时间感知阈值取色；关 = 两环同色，取该 provider 的整体健康度。
    ///
    /// 默认 **true**：两环表达的是两个**独立**的窗口，5h 还紧而周还很空时把它们
    /// 画成同一个颜色，等于抹掉了这条信息。给 true 意味着升级后环色会变
    /// （之前两环恒同色），但变化的方向只有"更准"——整体档位不会因为
    /// 逐窗口取色而变得更乐观（外环取的就是 5h 窗口本身的档位）。
    var independentRingColors: Bool

    init(
        mode: EdgeDockMode = .default,
        edge: DockEdge,
        offset: Double,
        screenUUID: String? = nil,
        hideInFullscreen: Bool = true,
        compactSize: EdgeDockCompactSize = .default,
        independentRingColors: Bool = true
    ) {
        self.mode = mode
        self.edge = edge
        self.offset = offset
        self.screenUUID = screenUUID
        self.hideInFullscreen = hideInFullscreen
        self.compactSize = compactSize
        self.independentRingColors = independentRingColors
    }

    enum CodingKeys: String, CodingKey {
        case mode, edge, offset, screenUUID, hideInFullscreen
        case compactSize, independentRingColors
    }

    /// 自定义 decode 只为一件事：`mode` 与 `hideInFullscreen` 是后加字段，旧
    /// config.json 里没有，合成版 Codable 会因此**整体解码失败** —— 而外层
    /// `ConfigStore` 对 edgeDock 用的是 `try?`（坏值按没配过处理），失败意味着
    /// 用户已经拖到屏幕另一边的 dock 被静默重置回默认位置。
    ///
    /// **旧配置里的 `enabled` / `autoHideMode` 不做映射**，一律回落到默认形态：
    /// 那两个布尔已经被 `mode` 取代，再维护一张映射表就要为"没人能看见的旧字段"
    /// 一直养着它；边缘状态窗在本版本里仍是未发布功能，行为回落到默认形态的
    /// 代价比"照顾旧字段"小。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 形态先按字符串解再查表，而不是 `decodeIfPresent(EdgeDockMode.self)`：
        // 后者遇到手改出来的未知值（`"mode": "magic"`）会**抛错**，整块解码失败，
        // 外层的 `try?` 随即把用户拖到另一条边、某一位置的 dock 一起重置掉。
        // 这里回落成默认形态，坏的是一个字段而不是整块配置——正好是这个自定义
        // decode 存在的理由。
        if let raw = try container.decodeIfPresent(String.self, forKey: .mode),
           let parsed = EdgeDockMode(rawValue: raw) {
            mode = parsed
        } else {
            mode = .default
        }
        // `edge` / `offset` 同样**逐字段容错**：手改 config.json 时少写一个 `edge`、
        // 或者把 `0.2` 写成字符串 `"0.2"`，都不该让整块 edgeDock 报废。
        // 报废的后果特别重：外层 `ConfigStore` 对这一块用 `try?`（坏值按没配过处理），
        // 于是**形态**（用户特意选的）和**拖好的位置**会一起静默重置回默认——而那
        // 正是这个自定义 decode 存在的理由。`mode` 当初已经是这么处理的，剩下两个
        // 字段漏了；`offset` 另有 `normalized` 负责把越界/非有限值拉回 [0, 1]。
        edge = (try? container.decode(DockEdge.self, forKey: .edge)) ?? EdgeDockConfig.default.edge
        offset = (try? container.decode(Double.self, forKey: .offset)) ?? EdgeDockConfig.default.offset
        // 后加字段：缺失 = 没指定屏 = 旧行为（跟随所在屏）。这里**不做**"从几何
        // 位置反推是哪块屏"的兼容——猜错的代价是 dock 静默跑掉，比继续跟随更糟。
        screenUUID = try container.decodeIfPresent(String.self, forKey: .screenUUID)
        // 后加字段，缺省 true 保持旧配置的行为不变。
        hideInFullscreen = try container.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? true
        // 后加字段，同样逐字段容错。**未知字符串也回落默认**而不是
        // `decodeIfPresent(EdgeDockCompactSize.self)`：后者遇到手改出来的
        // `"compactSize": "gigantic"` 会抛错，整块 edgeDock 报废，用户拖好的
        // 位置与贴边方向一起被外层的 `try?` 重置掉——为一个纯观感字段赔上
        // 整个 dock 的位置不划算。
        if let raw = try container.decodeIfPresent(String.self, forKey: .compactSize),
           let parsed = EdgeDockCompactSize(rawValue: raw) {
            compactSize = parsed
        } else {
            compactSize = .default
        }
        // 后加字段，缺省 true（与 `compactSize` 同款容错理由）。
        independentRingColors = try container.decodeIfPresent(
            Bool.self, forKey: .independentRingColors
        ) ?? true
    }

    static let `default` = EdgeDockConfig(mode: .default, edge: .right, offset: 0.5)

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
            mode: mode,
            edge: edge,
            offset: offset.isFinite ? min(max(offset, 0), 1) : 0.5,
            screenUUID: screenUUID,
            hideInFullscreen: hideInFullscreen,
            compactSize: compactSize,
            independentRingColors: independentRingColors
        )
    }
}

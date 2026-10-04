import XCTest
import CoreGraphics
@testable import LLM_monitor

/// dock 测试的共享 fixture 基类。
///
/// 这些构造器跨多个测试文件复用（`makeDockFrame` 一个人就服务 4 组），
/// 所以收在这里由子类继承——拆文件时 138 个测试体一个字符都不用改。
/// 不是 `final`：它自己没有 `test*` 方法，只提供 fixture。
class EdgeDockTestCase: XCTestCase {
    /// visibleFrame 模拟：主屏 1920x1080，顶部菜单栏 25，Dock 在底部 60。
    let visible = CGRect(x: 0, y: 60, width: 1920, height: 995)

    /// 贴右边、4 个圆、offset 居中的 dock frame。
    /// `size` 显式给出时用它（简版形态的行距与完整版不同，测简版时必须给）。
    func makeDockFrame(
        edge: DockEdge,
        entryCount: Int,
        offset: Double = 0.5,
        size: CGSize? = nil
    ) -> CGRect {
        EdgeDockGeometry.frame(
            visibleFrame: visible,
            edge: edge,
            size: size ?? EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge),
            offset: offset
        )
    }

    /// 模拟 `EdgeDockContentView` 的真实排版，算出每行在**窗口内**的矩形。
    ///
    /// 竖排 = `VStack`（沿 y 堆叠，第 0 行在上），横排 = `HStack`（沿 x 堆叠，
    /// 第 0 列在左），外面套一层 `padding`。SwiftUI 坐标 y 向下、原点在左上。
    func swiftUILaidOutRows(entryCount: Int, edge: DockEdge) -> [CGRect] {
        let vertical = edge.isVertical
        // 竖排每项高 rowHeight、横排每项宽 diameter，步进也不同（rowStep / columnStep）。
        let itemExtent = vertical ? EdgeDockGeometry.rowHeight : EdgeDockGeometry.diameter
        let step = vertical ? EdgeDockGeometry.rowStep : EdgeDockGeometry.columnStep
        let across = vertical ? EdgeDockGeometry.diameter : EdgeDockGeometry.rowHeight
        return (0..<entryCount).map { index in
            let along = EdgeDockGeometry.padding + CGFloat(index) * step
            return vertical
                ? CGRect(
                    x: EdgeDockGeometry.padding, y: along,
                    width: across, height: itemExtent
                )
                : CGRect(
                    x: along, y: EdgeDockGeometry.padding,
                    width: itemExtent, height: across
                )
        }
    }

    /// 把窗口内（y 向下）矩形翻成屏幕坐标（y 向上）。
    func flippedToScreen(_ rows: [CGRect], in dock: CGRect) -> [CGRect] {
        rows.map { row in
            CGRect(
                x: dock.minX + row.minX,
                y: dock.maxY - row.maxY,
                width: row.width, height: row.height
            )
        }
    }

    func makeModel(
        name: String,
        intervalPercent: Double?,
        weeklyPercent: Double? = nil,
        now: Date = Date()
    ) -> ModelQuota {
        // 窗口标记为 present 时**必须**同时给出 reset 时间：`ModelQuota` 在 debug 下
        // 对"present 但没有重置时间"是 assertionFailure 直接 trap，那不是合法夹具。
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: intervalPercent ?? 0,
            intervalStatus: intervalPercent == nil ? .absent : .present,
            intervalResetsAt: intervalPercent == nil ? nil : now.addingTimeInterval(2 * 3600),
            intervalWindowSeconds: intervalPercent == nil ? nil : 18000,
            weeklyTotalCount: 100,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: weeklyPercent ?? 0,
            weeklyStatus: weeklyPercent == nil ? .absent : .present,
            weeklyResetsAt: weeklyPercent == nil ? nil : now.addingTimeInterval(3 * 24 * 3600),
            weeklyWindowSeconds: weeklyPercent == nil ? nil : 604800
        )
    }

    /// 投影测试里色档断言的固定时刻。
    ///
    /// 周色档是"时间感知"的（阈值 = min(剩余时间%, 50)），用真实 `Date()` 的话同一条
    /// 断言会随运行时刻漂——尤其是跨周边界时，测试会在某天突然红。
    /// `static`：夹具函数要拿它当默认参数，默认参数里不能用实例成员。
    static let makeNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// 显式给出窗口时间比例的 model 夹具。
    ///
    /// 与 `makeModel` 的区别只有一处：周窗口的 `resetsAt` 由 `weeklyTimeFraction`
    /// 反推，而不是"从 `Date()` 起往后 3 天"。色档测试要断言的就是"同一个百分比
    /// 在不同剩余时间下给出不同颜色"，所以剩余时间必须是输入而不是副作用。
    func quotaModel(
        intervalPercent: Double?,
        weeklyPercent: Double? = nil,
        weeklyTimeFraction: Double? = nil,
        now: Date = EdgeDockTestCase.makeNow
    ) -> ModelQuota {
        ModelQuota(
            modelName: "g",
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: intervalPercent ?? 0,
            intervalStatus: intervalPercent == nil ? .absent : .present,
            intervalResetsAt: intervalPercent == nil ? nil : now.addingTimeInterval(2 * 3600),
            // 5h 短窗（< 24h）：`intervalTimeRemainingFraction` 按定义返回 nil，
            // 外环色档走固定 30% 黄线。
            intervalWindowSeconds: intervalPercent == nil ? nil : 18000,
            weeklyTotalCount: 100,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: weeklyPercent ?? 0,
            weeklyStatus: weeklyPercent == nil ? .absent : .present,
            weeklyResetsAt: weeklyPercent == nil
                ? nil
                : now.addingTimeInterval((weeklyTimeFraction ?? 1) * 604_800),
            weeklyWindowSeconds: weeklyPercent == nil ? nil : 604_800
        )
    }

    /// 只有周窗口、且剩余时间比例显式给定的 model。
    func weeklyModel(percent: Double, timeFraction: Double) -> ModelQuota {
        quotaModel(intervalPercent: nil, weeklyPercent: percent, weeklyTimeFraction: timeFraction)
    }

    func makeStatus(
        id: String,
        kind: ProviderKind = .codexChatGpt,
        enabled: Bool = true,
        state: ProviderStatus.State
    ) -> ProviderStatus {
        var status = ProviderStatus(
            id: id,
            displayName: id.uppercased(),
            kind: kind,
            iconSystemName: "circle",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: state
        )
        status.isEnabled = enabled
        return status
    }

    func makeInfo(_ models: [ModelQuota]) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    /// 用几何常量推算的行位置 vs 视图实测的行位置，允许存在偏差；
    /// 命中判定必须以实测为准，否则偏差会逐行累积成"hover A 弹出 B"。
    func measuredRows(edge: DockEdge, entryCount: Int, drift: CGFloat = 0) -> [CGRect] {
        let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
        let dock = EdgeDockGeometry.frame(visibleFrame: visible, edge: edge, size: size, offset: 0.5)
        var rects: [CGRect] = []
        for index in 0..<entryCount {
            let c = EdgeDockGeometry.rowCenter(dockFrame: dock, edge: edge, index: index)
            let row = EdgeDockGeometry.rowHeight + drift
            let along = row / 2 - drift / 2
            switch edge {
            case .right:  rects.append(CGRect(x: dock.minX, y: c.y - along, width: dock.width, height: row))
            case .left:   rects.append(CGRect(x: dock.minX, y: c.y - along, width: dock.width, height: row))
            case .bottom: rects.append(CGRect(x: c.x - along, y: dock.minY, width: row, height: dock.height))
            case .top:    rects.append(CGRect(x: c.x - along, y: dock.minY, width: row, height: dock.height))
            }
        }
        return rects
    }

    /// 命中测试的**圆**矩形：按 `circleCenter` 定位、按 `diameter` 出尺寸，
    /// 也就是 `EdgeDockContentView` 实际上报的那一份。
    ///
    /// 不能拿 `measuredRows` 顶替：`circleIndex` 的判定半径就是 `rect.width / 2`，
    /// 传进 70pt 宽的行矩形等于把半径偷偷放大到 35pt——断言照样绿，测的却是另一套
    /// 几何。行矩形比圆大（54 高 vs 38 直径）、行中心还在圆心下方 8pt，用它取样
    /// 与"圆能不能被指中"无关。
    func measuredCircles(
        edge: DockEdge,
        entryCount: Int,
        drift: CGFloat = 0
    ) -> [CGRect] {
        let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
        let dock = EdgeDockGeometry.frame(visibleFrame: visible, edge: edge, size: size, offset: 0.5)
        return (0..<entryCount).map { index in
            // drift 模拟"实测矩形与常量推算对不上"：**只平移、不改尺寸**——
            // 尺寸一改就测不到"判定是否跟着实测走"了。
            let c = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: edge, index: index)
            return CGRect(
                x: c.x + drift - EdgeDockGeometry.diameter / 2,
                y: c.y + drift - EdgeDockGeometry.diameter / 2,
                width: EdgeDockGeometry.diameter,
                height: EdgeDockGeometry.diameter
            )
        }
    }

    // 「第 i 个矩形」必须严格等于「第 i 个条目」，任何来源的顺序错位都算失败。

    func rowRectsByID(
        _ entries: [EdgeDockEntry],
        edge: DockEdge = .right,
        entryCount: Int? = nil,
        drift: CGFloat = 0
    ) -> [String: CGRect] {
        let rects = measuredRows(edge: edge, entryCount: entryCount ?? entries.count, drift: drift)
        return Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), rects))
    }

    func makeEntries(_ ids: [String]) -> [EdgeDockEntry] {
        ids.map {
            EdgeDockEntry(
                id: $0,
                displayName: $0.uppercased(),
                kind: .codexChatGpt,
                intervalFraction: 0.5,
                rawIntervalFraction: 0.5,
                weeklyFraction: 0.8,
                health: .healthy,
                intervalHealth: .healthy,
                weeklyHealth: .healthy
            )
        }
    }

    // 所以规则是：**任何输入下都必须返回可命中的行**，只能是准不准，不能是空。

    func panelFrame(edge: DockEdge, entryCount: Int) -> CGRect {
        let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
        return EdgeDockGeometry.frame(visibleFrame: visible, edge: edge, size: size, offset: 0.5)
    }

    static let probeScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    static let probePrimary: CGFloat = 1080

    static let probeOwnPID: pid_t = 4242

    func probe(
        _ entries: [FullscreenProbe.WindowEntry],
        own: pid_t = EdgeDockTestCase.probeOwnPID
    ) -> Bool {
        FullscreenProbe.containsFullscreenWindow(
            among: entries,
            screenFrame: EdgeDockTestCase.probeScreen,
            primaryScreenHeight: EdgeDockTestCase.probePrimary,
            ownProcessIdentifier: own
        )
    }

    func window(
        _ pid: pid_t, layer: Int = 0, _ rect: CGRect
    ) -> FullscreenProbe.WindowEntry {
        .init(ownerPID: pid, layer: layer, bounds: rect)
    }
}

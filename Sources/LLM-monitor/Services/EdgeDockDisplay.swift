import AppKit
import CoreGraphics

/// 屏幕的**稳定身份**。
///
/// 边缘窗要跨屏，就必须记住"是哪块屏"——而**不能**记 `NSScreen` 对象、数组下标或
/// 几何位置：
/// - `NSScreen` 是运行期对象，换屏 / 改分辨率会被系统换成新对象；
/// - `NSScreen.screens` 的顺序跟"主屏、排列方式"走，用户挪一下副屏就变了；
/// - 几何位置在两屏同分辨率同排列时完全相同，压根区分不出来。
///
/// 选 UUID（`CGDisplayCreateUUIDFromDisplayID`）而不是 `CGDirectDisplayID` /
/// `NSScreenNumber`：后两者是**本次开机枚举出来的编号**，换接口、重插、接扩展坞后
/// 可能变，dock 会凭空跑到另一块屏上。UUID 是系统为"这块物理显示器"生成的稳定
/// 标识，不随这些变化。
enum EdgeDockDisplay {
    /// `NSScreen` 对应的 display id（本次开机内有效，够用来做同屏比较）。
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// display id → UUID 的记忆化。
    ///
    /// `CGDisplayCreateUUIDFromDisplayID` 实测 **15µs/次**（要走一次窗口服务器），
    /// 而 `targetScreen` 在拖拽的**每个事件**上都会被问一遍。同一块显示器在一次
    /// 开机期间不会换 UUID，所以按 display id 记一份就够；拔屏后由 `pruneCache`
    /// 清掉（挂在 `didChangeScreenParameters` 上，拔插 / 改分辨率 / 改排列都会发）。
    private static var cache: [CGDirectDisplayID: String] = [:]

    /// `NSScreen` 对应的稳定 UUID。
    static func uuid(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen) else { return nil }
        if let cached = cache[id] { return cached }
        // `takeRetainedValue`：文档写明返回的 CFUUID 由调用方持有。
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let value = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String
        cache[id] = value
        return value
    }

    /// 丢掉已经不在的显示器的记忆（拔屏）。挂在屏幕参数变化通知上调用。
    static func pruneCache(to screens: [NSScreen]) {
        let live = Set(screens.compactMap(displayID(of:)))
        cache = cache.filter { live.contains($0.key) }
    }

    /// 纯逻辑：在 `NSScreen.screens` 的 UUID 列表里找配置指定的那一块，返回下标。
    ///
    /// **找不到必须返回 nil 而不是兜底到某一块**——调用方拿到 nil 才知道"用户拔了
    /// 屏"，可以顺手把配置改写回落；在这里悄悄兜底到第一块，配置就会一直指向一块
    /// 不存在的屏，之后每次启动都算错一次。
    static func matchingIndex(preferred: String?, keys: [String]) -> Int? {
        // 空串同样当"没配"：手改 config.json 写出 `"screenUUID": ""` 时不该去匹配
        // 一块空 UUID 的屏（也匹配不上，但要让调用方看到"没配"这个事实）。
        guard let preferred, !preferred.isEmpty else { return nil }
        return keys.firstIndex(of: preferred)
    }

    /// 纯逻辑：拖拽时鼠标是否越到了**另一块**屏，返回那块屏的下标。
    ///
    /// 两个条件缺一不可：
    /// - **display id 不同**：同一块显示器的另一个 `NSScreen` 对象不算越界；镜像屏
    ///   会给出**相同**的 display id，鼠标在镜像的那一半上时也不该触发换屏——换过去
    ///   只是把窗口挪到同一个物理显示器的另一面，`visibleFrame` 却是另一套坐标，
    ///   位置会算错。
    /// - **鼠标落在它的 `visibleFrame` 内**：相邻两屏拼接时边界只有一条，鼠标在
    ///   边界上对两块屏都算"在内"，靠距离判断会来回抖。
    static func crossedIndex(
        currentDisplayID: CGDirectDisplayID?,
        mouse: CGPoint,
        candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)]
    ) -> Int? {
        // 认不出当前屏的 display id 时不敢换屏：换错了就是 dock 消失在另一块屏上，
        // 而用户连"为什么"都看不到（窗口在看不见的地方）。
        guard let currentDisplayID else { return nil }
        for (index, candidate) in candidates.enumerated() {
            guard let id = candidate.displayID, id != currentDisplayID,
                  candidate.visibleFrame.contains(mouse)
            else { continue }
            return index
        }
        return nil
    }

    /// 找出配置指定的那一块屏。匹配逻辑本身在 `matchingIndex`（纯函数，可单测），
    /// 这里只负责把 `NSScreen.screens` 摊成同序的 UUID 列表。
    static func matchingScreen(preferred: String?, screens: [NSScreen]) -> NSScreen? {
        // 取不到 UUID 的屏（极老的系统 / 无 display id）落成空串，永远匹配不上——
        // 与其拿它去比，不如当成"这块屏没有身份"，让调用方走回落。
        let keys = screens.map { uuid(of: $0) ?? "" }
        guard let index = matchingIndex(preferred: preferred, keys: keys) else { return nil }
        return screens[index]
    }
}

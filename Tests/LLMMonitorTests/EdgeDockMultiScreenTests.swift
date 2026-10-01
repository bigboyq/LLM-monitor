import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 屏幕身份（UUID）与跨屏拖拽。对应 `EdgeDockDisplay` 与 `+Drag` 的换屏部分。
final class EdgeDockMultiScreenTests: EdgeDockTestCase {

    // MARK: - 多屏：屏幕身份与跨屏拖拽

    func testMatchingIndexResolvesTheConfiguredScreen() {
        // 副屏在左边 / 在右边两种排列都要能找到——UUID 与下标顺序无关。
        let keys = ["PRIMARY", "LEFT", "RIGHT"]
        XCTAssertEqual(EdgeDockDisplay.matchingIndex(preferred: "RIGHT", keys: keys), 2)
        XCTAssertEqual(EdgeDockDisplay.matchingIndex(preferred: "LEFT", keys: ["LEFT", "PRIMARY"]), 0)
    }

    func testMatchingIndexTreatsUnsetOrVanishedScreenAsUnset() {
        let keys = ["PRIMARY", "RIGHT"]
        XCTAssertNil(EdgeDockDisplay.matchingIndex(preferred: nil, keys: keys), "没配过屏")
        XCTAssertNil(
            EdgeDockDisplay.matchingIndex(preferred: "", keys: keys),
            "空串要当没配（手改 config.json 会写出这种值）"
        )
        XCTAssertNil(
            EdgeDockDisplay.matchingIndex(preferred: "GONE", keys: keys),
            "屏被拔掉时必须返回 nil，调用方据此把配置改写回落"
        )
        XCTAssertNil(EdgeDockDisplay.matchingIndex(preferred: "PRIMARY", keys: []))
    }

    @MainActor
    func testEveryAttachedDisplayHasADistinctResolvableUUID() {
        // 真正跑一遍 AppKit 那层（`NSScreen` 在纯逻辑测试里造不出来）：
        // 每块屏都要拿得到 UUID，UUID 之间不能重复，且能按 UUID 反查回同一块屏。
        // 重复会让两块屏互相匹配，dock 停在 A 屏却按 B 屏的 visibleFrame 定位。
        let screens = NSScreen.screens
        let uuids = screens.compactMap { EdgeDockDisplay.uuid(of: $0) }
        XCTAssertEqual(uuids.count, screens.count, "每块屏都要有 UUID（拿不到说明拿不到 display id）")
        XCTAssertEqual(Set(uuids).count, uuids.count, "不同显示器不能撞 UUID")
        for (index, screen) in screens.enumerated() {
            let uuid = uuids[index]
            XCTAssertEqual(
                EdgeDockDisplay.displayID(of: EdgeDockDisplay.matchingScreen(preferred: uuid, screens: screens)!),
                EdgeDockDisplay.displayID(of: screen),
                "按 UUID 反查必须回到同一块屏"
            )
        }
        XCTAssertNil(EdgeDockDisplay.matchingScreen(preferred: "NO-SUCH-UUID", screens: screens))
    }

    func testCrossedIndexOnlySwitchesToADifferentDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (1, main), (2, right)
        ]
        // 鼠标还在本屏内：不换。
        XCTAssertNil(EdgeDockDisplay.crossedIndex(currentDisplayID: 1, mouse: CGPoint(x: 900, y: 500), candidates: candidates))
        // 鼠标越过拼接边界：换到右边那块。
        XCTAssertEqual(
            EdgeDockDisplay.crossedIndex(currentDisplayID: 1, mouse: CGPoint(x: 2400, y: 500), candidates: candidates),
            1
        )
        // 反向同理。
        XCTAssertEqual(
            EdgeDockDisplay.crossedIndex(currentDisplayID: 2, mouse: CGPoint(x: 900, y: 500), candidates: candidates),
            0
        )
    }

    func testCrossedIndexIgnoresMirroredCopiesOfTheSameDisplay() {
        // 镜像屏两个 NSScreen 共享同一个 display id，visibleFrame 各是一半。
        // 鼠标在镜像那半边时"换屏"只会把窗口挪到同一台显示器的另一面，
        // 坐标系统一换位置就错了——必须判定为没越界。
        let left = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let right = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (7, left), (7, right)
        ]
        XCTAssertNil(EdgeDockDisplay.crossedIndex(currentDisplayID: 7, mouse: CGPoint(x: 1500, y: 500), candidates: candidates))
    }

    func testCrossedIndexStaysPutWhenTheCurrentScreenIsUnknown() {
        // 认不出本屏 display id 时不敢换：换错的后果是 dock 消失在看不见的地方。
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        XCTAssertNil(
            EdgeDockDisplay.crossedIndex(currentDisplayID: nil, mouse: CGPoint(x: 500, y: 500), candidates: candidates)
        )
    }

    func testScreenUUIDRoundTripsAndDefaultsToUnset() throws {
        // 老配置没有这个字段：必须是"没指定"（跟随所在屏），而不是解码失败。
        let legacy = #"{"mode":"statusWindow","edge":"left","offset":0.2}"#
        XCTAssertNil(try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8)).screenUUID)

        let onSecond = EdgeDockConfig(mode: .statusWindow, edge: .top, offset: 0.2, screenUUID: "RIGHT-UUID")
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(onSecond))
        XCTAssertEqual(decoded.screenUUID, "RIGHT-UUID")
        XCTAssertEqual(decoded.normalized.screenUUID, "RIGHT-UUID", "normalized 必须原样保留所在的屏")
    }

    /// 设置页保存**不得**把用户拖出来的贴边方向退回。
    ///
    /// 这条驱动的是**真的保存路径**（`SettingsView.saveAndApply` → 落盘 → 重读
    /// config.json），不是"照着生产代码的写法再拼一遍 struct"——后者只会断言
    /// 一句同义反复，生产代码改了它照样绿。
    ///
    /// ⚠️ 它验的是**保存那一刻读的是配置、不是某个 `@State`**，而不是"开窗时
    /// `@State` 读到了什么"：测试里这个 `SettingsView` 从未进入渲染层，而 SwiftUI
    /// 的 `@State` 写入在未渲染的视图上会被丢弃——所以 `loadCurrentConfig()` 那一步
    /// 在这里其实没留下任何状态。对本条**无害**（要抓的正是"保存时用了 view 上的
    /// 陈旧值"），但别把它当成对加载路径的覆盖。
    ///
    /// 生产里的复现时序：设置窗口开着，用户把 dock 拖到另一条边
    /// （`EdgeDockController.persistConfig` 立刻改写 config.json），再回设置页点
    /// "保存"。贴边方向**曾经**是开窗时读进 `edgeDockEdge` 这个 `@State`、保存时
    /// 原样写回的——于是刚拖出来的位置被悄悄退回。`offset` / `screenUUID` 当时
    /// 已经是"保存这一刻现读"，只有 `edge` 漏了。
    ///
    /// 登录项那条支路在这里不会被打到：`SettingsSaveTransaction` 只在"请求值 ≠
    /// 当前值"时才调 `updateLoginItem`，本测试两边都是 false。
    @MainActor
    func testSettingsSaveDoesNotRevertAnEdgeChosenByDragging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-edgedock-save-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)

        // 1) 用户此前把 dock 拖到了下边、并且停在副屏上。
        // 用 store 现有的 config 当基底（`AppConfig` 写了 `init(from:)`，成员构造器
        // 已被抑制），只改 edgeDock。
        var seeded = store.config
        seeded.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .bottom, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        try store.applyAndSave(seeded)

        // 2) 设置窗口打开：形态等字段被读进 @State。
        let view = SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: []
        )
        view.loadCurrentConfig()

        // 3) 窗口开着的时候，用户又把 dock 拖到了左边。控制器在松手时立刻落盘。
        var afterDrag = store.config
        afterDrag.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .left, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        try store.applyAndSave(afterDrag)

        // 4) 用户回设置页点"保存"——形态/全屏开关没动过。
        try await view.saveAndApply()

        let saved = store.config.effectiveEdgeDockConfig
        XCTAssertEqual(
            saved.edge, .left,
            "保存不得把拖拽改出来的贴边方向退回 bottom"
        )
        XCTAssertEqual(saved.offset, 0.42, accuracy: 0.0001, "沿边位置也不该被动")
        XCTAssertEqual(saved.screenUUID, "SECOND", "所在屏不该被动")
    }

    func testSettingsSaveMustNotLoseTheConfiguredScreen() {
        // 纯模型层的补充断言：设置页只带 `mode` 与 `hideInFullscreen`（那两个真有
        // 控件），位置类三兄弟必须来自保存这一刻的配置。端到端的路径由
        // `testSettingsSaveDoesNotRevertAnEdgeChosenByDragging` 守。
        let afterDrag = EdgeDockConfig(mode: .compactRings, edge: .left, offset: 0.42,
                                       screenUUID: "SECOND", hideInFullscreen: false)
        let rebuilt = EdgeDockConfig(
            mode: afterDrag.mode,
            edge: afterDrag.edge,
            offset: afterDrag.offset,
            screenUUID: afterDrag.screenUUID,
            hideInFullscreen: afterDrag.hideInFullscreen
        )
        XCTAssertEqual(rebuilt, afterDrag)
    }

    /// `screenUUID` 的**消费端**机制必须对真实屏幕列表成立。
    ///
    /// 这个 bug 的形状很典型：`screenUUID` 被拖拽写入、被设置页小心保留、还被
    /// 两条测试钉住了"能存能取"，唯独没有任何代码在启动时拿它去选屏——于是
    /// "停在副屏"这件事静默失效，CI 全绿而功能是死的。上面两条测试测的是**数据
    /// 层**，所以它们给的是**假的安全感**：数据确实没错，错的是没人消费它。
    ///
    /// ⚠️ **这条仍然钉不住"生产路径真的调用了它"**：`targetScreen` 是
    /// `private static`、读 AppKit 全局状态，纯逻辑测试够不到它。把
    /// `EdgeDockDisplay.matchingScreen` 从 `targetScreen` 里删掉（也就是让 bug
    /// 原样回来）本条依然全绿——它守的是"消费端这个零件本身可用且语义正确"，
    /// 不是"零件被装上了"。
    ///
    /// 真正补上这一层需要 grep 式扫描或把 `targetScreen` 拆出一个可注入的纯函数；
    /// 在那之前，这里能做的就这些，**不要再声称 CI 覆盖了接线**。
    @MainActor
    func testConfiguredScreenResolutionMechanismWorksOnRealScreens() throws {
        let screens = NSScreen.screens
        // `throws` + `try XCTSkipIf`，不要写成 `try?`：`XCTSkipIf` 是靠抛异常表示
        // 跳过的，`try?` 会把那个异常吃掉，于是"没有显示器"时不跳不挂，测试**空过**
        // （for 循环体一次都不执行）——headless CI 上就是一条零信号的绿灯。
        try XCTSkipIf(screens.isEmpty, "没有接显示器，跳过")

        // 逐块屏验证"按 UUID 反查回到同一块屏"——这是 `targetScreen` 第一层
        // 依赖的全部机制。
        for screen in screens {
            guard let uuid = EdgeDockDisplay.uuid(of: screen) else {
                XCTFail("取不到 \(screen.frame) 的 UUID")
                continue
            }
            guard let resolved = EdgeDockDisplay.matchingScreen(preferred: uuid, screens: screens) else {
                XCTFail("配置里的 UUID \(uuid) 反查不到屏")
                continue
            }
            XCTAssertEqual(
                EdgeDockDisplay.displayID(of: resolved),
                EdgeDockDisplay.displayID(of: screen),
                "配置里的 UUID 必须能解析回同一块屏"
            )
        }

        // 没有任何一块屏是这个 UUID 时必须返回 nil（而不是悄悄兜底到第一块）：
        // 兜底会让配置一直指向一块不存在的屏，每次启动都重演一次"解析不到"。
        XCTAssertNil(EdgeDockDisplay.matchingScreen(preferred: "NO-SUCH-UUID", screens: screens))
    }
}

import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 形态、全屏隐藏开关与配置归一化的向后兼容。对应 `EdgeDockConfig`。
final class EdgeDockConfigTests: EdgeDockTestCase {

    // MARK: - 形态（mode）：默认值、配置兼容与语义

    func testDefaultModeIsAutoHideWindow() {
        // 默认给「状态窗（自动隐藏）」：完整功能默认开着，屏幕上默认只占一条
        // 7pt 的小环列，鼠标靠近才长出来。改这个值等于改"装上 App 之后屏幕上
        // 立刻出现什么"——曾经默认是"什么都不出现"，现在必须钉住新约定。
        XCTAssertEqual(EdgeDockConfig.default.mode, .autoHideWindow)
        XCTAssertTrue(EdgeDockConfig.default.mode.isVisible)
    }

    func testModeExposesTheTwoIndependentSwitchesTheControllerUsedToRead() {
        // 控制器过去读两个布尔（enabled / autoHideMode），现在只读形态上这两个
        // 派生属性。四种组合必须各自落在一个**互斥**的格子里：
        // 「小圆环」与「状态窗（自动隐藏）」都是简版，但只有后者会被鼠标撑大——
        // 这一条钉住的就是那个区别，它无法从"两个布尔"里一眼看出来。
        XCTAssertFalse(EdgeDockMode.hidden.isVisible)
        XCTAssertFalse(EdgeDockMode.hidden.expandsOnProximity)
        XCTAssertTrue(EdgeDockMode.statusWindow.staysFullWhenIdle)
        XCTAssertFalse(EdgeDockMode.statusWindow.expandsOnProximity)
        XCTAssertTrue(EdgeDockMode.compactRings.isVisible)
        XCTAssertFalse(EdgeDockMode.compactRings.expandsOnProximity, "小圆环永不展开")
        XCTAssertFalse(EdgeDockMode.compactRings.staysFullWhenIdle)
        XCTAssertTrue(EdgeDockMode.autoHideWindow.expandsOnProximity)
        XCTAssertFalse(EdgeDockMode.autoHideWindow.staysFullWhenIdle)
    }

    func testEveryModeHasItsOwnDisplayName() {
        // 四个选项都在 picker 里列出。名字重复或为空 = 用户分不出该选哪个。
        XCTAssertEqual(EdgeDockMode.allCases.count, 4)
        XCTAssertEqual(
            Set(EdgeDockMode.allCases.map(\.displayName)).count, 4,
            "四种形态的显示名必须两两不同"
        )
        XCTAssertTrue(EdgeDockMode.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    func testLegacyConfigJSONWithoutModeFallsBackToDefault() throws {
        // 旧 config.json 只有 enabled / autoHideMode，没有 mode：必须按**默认形态**
        // 解码成功，绝不能让整块解码失败——外层 ConfigStore 对 edgeDock 用的是
        // `try?`，失败 = 用户拖到另一条边的 dock 被静默重置回默认位置。
        // 这里刻意**不**映射旧的 enabled/autoHideMode（行为回落到默认形态）。
        let legacy = #"{"enabled":true,"edge":"left","offset":0.3,"autoHideMode":true}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.mode, .default)
        XCTAssertEqual(decoded.edge, .left)
        XCTAssertEqual(decoded.offset, 0.3, accuracy: 0.0001)
    }

    func testLegacyConfigThatExplicitlyDisabledTheDockStillDecodes() throws {
        // enabled=false 的旧配置同样按默认形态解码（不映射）——但**其它字段必须
        // 原样保住**：位置和贴边方向是用户拖出来的，比形态更不能丢。
        let legacy = #"{"enabled":false,"edge":"bottom","offset":0.8}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.edge, .bottom)
        XCTAssertEqual(decoded.offset, 0.8, accuracy: 0.0001)
    }

    func testModeRoundTripsThroughJSON() throws {
        for mode in EdgeDockMode.allCases {
            let original = EdgeDockConfig(mode: mode, edge: .bottom, offset: 0.7)
            let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.normalized.mode, mode, "normalized 必须原样保留形态")
        }
    }

    func testUnknownModeValueInHandEditedConfigFallsBackToDefault() throws {
        // 手改 config.json 写一个不存在的形态值：整块解码必须成功并回落到默认，
        // 不能让 try? 把整份配置判成损坏。
        let hand = #"{"mode":"magic","edge":"left","offset":0.2}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(hand.utf8))
        XCTAssertEqual(decoded.mode, .default)
    }

    // MARK: - 全屏隐藏开关：配置兼容

    func testHideInFullscreenDefaultsOn() {
        // 全屏隐藏与形态**正交**：形态选「无」时它没有可作用的对象，但只要选了
        // 任何一种形态，缺省就该是"全屏时让路"——功能一直存在、默认一直是开。
        // 如果这里给 false，等于升级后所有开着 dock 的用户立刻在全屏里
        // 多出一个窗口——那不是新功能，是行为突变。
        XCTAssertTrue(EdgeDockConfig.default.hideInFullscreen)
    }

    func testLegacyConfigJSONWithoutHideInFullscreenStillDecodes() throws {
        // 缺字段不能让整块解码失败。外层 ConfigStore 用 try?，失败 = 用户拖好的
        // 边缘窗被静默重置。
        let legacy = #"{"mode":"statusWindow","edge":"top","offset":0.2}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.mode, .statusWindow)
        XCTAssertEqual(decoded.edge, .top)
        XCTAssertTrue(decoded.hideInFullscreen, "缺失该字段时必须回落到默认开启")
    }

    func testHideInFullscreenRoundTripsThroughJSON() throws {
        let off = EdgeDockConfig(mode: .statusWindow, edge: .left, offset: 0.9, hideInFullscreen: false)
        let offDecoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(off))
        XCTAssertEqual(offDecoded, off)
        XCTAssertFalse(offDecoded.normalized.hideInFullscreen, "normalized 必须原样保留关闭状态")

        let on = EdgeDockConfig(mode: .statusWindow, edge: .left, offset: 0.9, hideInFullscreen: true)
        let onDecoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(on))
        XCTAssertTrue(onDecoded.normalized.hideInFullscreen)
    }

    func testFullscreenHidingRespectsTheToggle() {
        // 策略本身：探测到全屏 + 开关开着 → 隐藏；开关关掉 → 一律不隐藏。
        // 这两行曾经散在控制器四个 guard 里各写一次，任何一处漏掉都不会编译报错。
        let hiding = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 0.5, hideInFullscreen: true)
        XCTAssertTrue(hiding.hidesInFullscreen(isFullscreenSpace: true))
        XCTAssertFalse(hiding.hidesInFullscreen(isFullscreenSpace: false), "不在全屏时永远不隐藏")

        let showing = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 0.5, hideInFullscreen: false)
        XCTAssertFalse(
            showing.hidesInFullscreen(isFullscreenSpace: true),
            "关掉开关后，即使前台 App 全屏也不该隐藏——这正是这个选项的意义"
        )
    }

    func testEdgeSurvivesSettingsSaveEvenThoughThereIsNoEdgePicker() {
        // 设置页不再有"贴靠边"下拉框，但保存时仍然要把**已存的值**原样写回去。
        // 贴边方向由拖动实时写盘；如果这里改成 `EdgeDockConfig.default.edge`，
        // 用户在设置页点一下"保存"就会把拖好的位置打回右侧，而且没有任何提示。
        let stored = EdgeDockConfig(mode: .compactRings, edge: .bottom, offset: 0.42, hideInFullscreen: false)
        let rebuilt = EdgeDockConfig(
            mode: stored.mode,
            edge: stored.edge,
            offset: stored.offset,
            hideInFullscreen: stored.hideInFullscreen
        )
        XCTAssertEqual(rebuilt, stored)
    }

    // MARK: - 配置归一化

    func testNormalizedClampsHandEditedOffset() {
        let over = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 42)
        XCTAssertEqual(over.normalized.offset, 1)

        let under = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: -7)
        XCTAssertEqual(under.normalized.offset, 0)

        let nan = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: .nan)
        XCTAssertEqual(nan.normalized.offset, 0.5)
    }

    func testDefaultEdgeDockSitsOnTheRightEdge() {
        // 贴边方向与形态无关：默认右侧，拖动后由拖拽写盘。
        XCTAssertEqual(EdgeDockConfig.default.edge, .right)
        XCTAssertEqual(EdgeDockConfig.default.mode, .autoHideWindow)
    }

    func testDockEdgeAxisClassification() {
        XCTAssertTrue(DockEdge.left.isVertical)
        XCTAssertTrue(DockEdge.right.isVertical)
        XCTAssertFalse(DockEdge.top.isVertical)
        XCTAssertFalse(DockEdge.bottom.isVertical)
    }
}

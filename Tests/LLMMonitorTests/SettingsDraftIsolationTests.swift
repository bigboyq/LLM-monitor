import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 设置页草稿**不被无关的配置写入冲掉**。
///
/// 背景：边缘窗拖拽在松手时会调 `ConfigStore.applyAndSave` 写盘（只改
/// `edgeDock` 的贴边方向 / 沿边位置 / 所在屏），这是本分支新增的**第一个**
/// "非设置页、非启动期"的 config 写入方。设置页靠 `configStore.$config` 广播
/// 重载整张表单——而 dock 面板是 nonactivating 的，用户完全可以在设置窗口开着
/// 的时候去拖它。于是拖一次 dock，用户输了一半的 API key、刷新间隔、Bark 配置
/// 会被盘上的旧值**无声地**刷回去，没有任何视觉提示。
final class SettingsDraftIsolationTests: XCTestCase {

    @MainActor
    private func makeSettings() -> (view: SettingsView, state: AppState, store: ConfigStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-draft-isolation-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)
        return (SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: []
        ), state, store)
    }

    /// 拖 dock（只改位置）**不得**被当成"表单该重载"。
    ///
    /// 这条直接打 `hasFormRelevantChange`，也就是 `.onReceive` 里那道闸门。
    /// 断言两侧：
    ///  - 只动位置 → 判 false（不重载，草稿保住）
    ///  - 动任何一个表单字段 → 判 true（该重载，否则手改 config.json 就不生效了）
    ///
    /// 第二侧同样重要：只堵住位置那一种改动，很容易顺手把整条热重载一起堵死，
    /// 于是"手改 config.json 后设置页自动刷新"这个既有功能静默消失。
    @MainActor
    func testDockPositionWriteIsNotTreatedAsAFormChange() throws {
        let (view, _, store) = makeSettings()
        view.loadCurrentConfig()

        var base = store.config
        base.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .bottom, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        try store.applyAndSave(base)
        view.loadCurrentConfig()

        // ① 只动贴边方向 —— 拖 dock 的常态结果。
        var movedEdge = base
        movedEdge.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .left, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        XCTAssertFalse(
            SettingsView.hasFormRelevantChange(from: base, to: movedEdge),
            "只改边缘窗位置时不得重载表单（否则正在输入的 API key 会被刷回盘上旧值）"
        )

        // ② 只动沿边位置。
        var movedOffset = base
        movedOffset.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .bottom, offset: 0.77,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        XCTAssertFalse(SettingsView.hasFormRelevantChange(from: base, to: movedOffset), "沿边位置同样与表单无关")

        // ③ 换屏。
        var movedScreen = base
        movedScreen.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .bottom, offset: 0.42,
            screenUUID: "THIRD", hideInFullscreen: true
        )
        XCTAssertFalse(SettingsView.hasFormRelevantChange(from: base, to: movedScreen), "所在屏同样与表单无关")

        // ④ 但形态是**设置页自己的控件**（picker），改了必须重载。
        var changedMode = base
        changedMode.edgeDock = EdgeDockConfig(
            mode: .statusWindow, edge: .bottom, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: true
        )
        XCTAssertTrue(
            SettingsView.hasFormRelevantChange(from: base, to: changedMode),
            "形态是表单控件，它变了却判成'与表单无关'就会让热重载失效"
        )

        // ⑤ 全屏隐藏开关同理。
        var changedHidden = base
        changedHidden.edgeDock = EdgeDockConfig(
            mode: .compactRings, edge: .bottom, offset: 0.42,
            screenUUID: "SECOND", hideInFullscreen: false
        )
        XCTAssertTrue(SettingsView.hasFormRelevantChange(from: base, to: changedHidden), "全屏隐藏开关必须触发重载")

        // ⑥ 一个与边缘窗完全无关的字段：刷新间隔。
        var changedInterval = base
        changedInterval.refreshIntervalSeconds = base.refreshIntervalSeconds + 1
        XCTAssertTrue(SettingsView.hasFormRelevantChange(from: base, to: changedInterval), "刷新间隔变了必须重载")

        // ⑦ 什么都没变。
        XCTAssertFalse(SettingsView.hasFormRelevantChange(from: base, to: base), "配置没变时不该重载")
    }

    /// 抹平位置字段的投影**不覆盖**其它字段：把两个只差边缘窗位置的配置投影一下，
    /// 它们必须相等；而把 provider 配置改掉再投影，必须仍然不等。
    ///
    /// 上一条从行为上已经覆盖了这些，但那是"经过闸门之后"的结果。这条直接钉住
    /// 投影本身——将来若有人把抹平写得太宽（比如整块 `edgeDock` 都抹掉），
    /// 形态变化就会被误判成"与表单无关"，而上一条 ④ 抓的正是后果。
    @MainActor
    func testPositionBlanketingDoesNotSwallowOtherFields() {
        let (_, _, store) = makeSettings()
        // `AppConfig` 写了 `init(from:)`，成员构造器已被抑制——以 store 现有配置为基底。
        var a = store.config
        a.edgeDock = EdgeDockConfig(mode: .compactRings, edge: .left, offset: 0.1, screenUUID: "X")
        var b = a
        b.edgeDock = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 0.9, screenUUID: nil)
        XCTAssertNotEqual(a.edgeDock, b.edgeDock, "前提：两份配置的边缘窗段确实不同")
        XCTAssertTrue(
            SettingsView.hasFormRelevantChange(from: a, to: b),
            "形态差异必须被看见——否则整块 edgeDock 被抹平会让形态变化失去热重载"
        )
    }
}

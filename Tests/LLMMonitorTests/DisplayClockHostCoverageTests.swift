import XCTest
@testable import LLM_monitor

/// 宿主覆盖护栏：凡是在 `Sources/LLM-monitor/` 里构建 AppKit SwiftUI 宿主的
/// 文件（内容含 `NSHostingView(` 或 `NSHostingController(`），必须把跨宿主
/// 展示时钟铺进 rootView——即文件里出现 `DisplayClockScope(`（定义见
/// `Sources/LLM-monitor/Views/DisplayClock.swift`）——或者在本文件的
/// `exemptedHostFiles` 里显式豁免并写明理由。没有宿主级注入时，卡内读
/// `\.displayDate` 的组件（高峰倒计时 / 新鲜度胶囊 / 重置倒计时）会落到环境键
/// `DisplayDateKey.defaultValue` 的 `static let` 进程级冻结值。这条护栏把
/// "渲染卡片的宿主必须注入"从靠人记变成 `swift test` 会红的检查。
///
/// 判据是文本包含（`DisplayClockScope(` 出现在文件任意位置即算注入，注释提及
/// 也满足）——刻意换低成本；"注入是否真的套在 rootView 上"由 review 兜底。
///
/// 局限：SwiftUI 原生宿主（MenuBarExtra label / 设置窗口）不走 `NSHostingView`
/// / `NSHostingController`，不在本扫描范围；本条护栏只覆盖 AppKit 浮层宿主
/// 这类真实出事口。
final class DisplayClockHostCoverageTests: XCTestCase {

    // #filePath 上溯到仓库根：文件位于仓库根下 Tests/LLMMonitorTests/ 内，
    // 删除「文件名 / LLMMonitorTests / Tests」三级后即为仓库根。
    // （与 IconAssetSyncTests.repoRoot() 同一模式。）
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → Tests/LLMMonitorTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → 仓库根
    }

    // 非源码检出场景（无 Sources/，例如只随测试包分发的场景）无法扫描宿主
    // 文件，跳过。
    private func requireSourceRoot() throws -> URL {
        let root = repoRoot()
        let sourceRoot = root.appendingPathComponent("Sources/LLM-monitor")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sourceRoot.path),
            "仓库根下无 Sources/LLM-monitor（非源码检出场景），跳过展示时钟宿主覆盖校验（computed root: \(sourceRoot.path)）"
        )
        return sourceRoot
    }

    /// 豁免清单：宿主文件（相对 `Sources/LLM-monitor/` 的路径）→ 理由。
    /// 新增豁免必须带一行理由；理由过期（宿主开始渲染读 `\.displayDate` 的
    /// 视图）时应改为注入 `DisplayClockScope`，而不是续期豁免。宿主文件改名或
    /// 删除后，过期条目会被本测试点名。
    private static let exemptedHostFiles: [String: String] = [
        // dock 主面板：只渲染圆环 + 数值（`EdgeDockContentView`），不含任何读
        // `\.displayDate` 的子视图，无需展示时钟。
        "Services/EdgeDockController+Window.swift":
            "dock 主面板（圆环+数值）不渲染读 \\.displayDate 的视图",
    ]

    /// 已知关键读端：这些文件必须仍在读 `\.displayDate`。防止改名/搬家把读端
    /// 悄悄扫空、或扫描口径失效后护栏空转。集合变化时先确认是有意的再改这里。
    private static let knownReaderFiles: Set<String> = [
        "Views/PeakIndicatorView.swift",
        "Views/ProviderCardView.swift",
        "Views/QuotaViews.swift",
        "Views/QuotaWindowUsageViews.swift",
    ]

    func testEveryAppKitHostingFileInjectsDisplayClockScopeOrIsExempted() throws {
        let sourceRoot = try requireSourceRoot()
        let fm = FileManager.default

        // 收集 Sources/LLM-monitor 下全部 .swift 的（相对路径, 内容）。
        guard let enumerator = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("无法枚举 \(sourceRoot.path)：宿主覆盖护栏的扫描失效，先修扫描再谈覆盖")
        }
        var contents: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.hasPrefix(sourceRoot.path + "/")
                ? String(url.path.dropFirst(sourceRoot.path.count + 1))
                : url.lastPathComponent
            contents[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertFalse(
            contents.isEmpty,
            "Sources/LLM-monitor 下扫不到任何 .swift：扫描路径失效，先修护栏"
        )

        // 宿主构建点：内容含 NSHostingView( 或 NSHostingController( 的文件。
        let hostFiles = contents
            .filter {
                $0.value.contains("NSHostingView(") || $0.value.contains("NSHostingController(")
            }
            .map { (relative: $0.key, content: $0.value) }
            .sorted { $0.relative < $1.relative }
        XCTAssertFalse(
            hostFiles.isEmpty,
            "Sources/LLM-monitor 里扫不到任何 NSHostingView( / NSHostingController( 宿主构建点："
                + "要么宿主全部改走了别的通道（那时本护栏需要重写口径），要么扫描失效。"
                + "先查清原因，再决定豁免清单的去留"
        )

        // 豁免清单保鲜：列在清单里的文件必须仍是当前扫出的宿主，否则条目过期。
        let hostRelativePaths = Set(hostFiles.map(\.relative))
        for exempt in Self.exemptedHostFiles.keys {
            XCTAssertTrue(
                hostRelativePaths.contains(exempt),
                "豁免清单条目 \(exempt) 已过期：它不再是扫出的宿主文件（改名 / 删除 / 不再构建宿主），"
                    + "从 DisplayClockHostCoverageTests.exemptedHostFiles 里删掉这条"
            )
        }

        // 核心断言：宿主要么注入，要么显式豁免。
        var missing: [String] = []
        for host in hostFiles {
            if host.content.contains("DisplayClockScope(") { continue }
            if Self.exemptedHostFiles[host.relative] != nil { continue }
            missing.append(host.relative)
        }
        XCTAssertTrue(
            missing.isEmpty,
            "以下宿主文件构建 NSHostingView / NSHostingController，但没有注入展示时钟：\n"
                + missing.map { "  - \($0)" }.joined(separator: "\n")
                + "\n修法二选一：把 rootView 包进 DisplayClockScope(clock:)（宿主自己持有一个 "
                + "DisplayClock、随宿主显隐 start/stop，参考 Views/HoverPanel.swift 的 "
                + "HoverPanelController.displayClock）；或确认该宿主确实不渲染读 \\.displayDate "
                + "的视图，把它加进 DisplayClockHostCoverageTests.exemptedHostFiles 并写明理由"
        )

        // 读端护栏：已知关键消费者必须仍在读 `\.displayDate`。
        let readerFiles = Set(
            contents.filter { $0.value.contains("\\.displayDate") }.keys
        )
        for known in Self.knownReaderFiles.sorted() {
            XCTAssertTrue(
                readerFiles.contains(known),
                "已知读端 \(known) 不再包含 \\.displayDate：读端集合变了（改名漏改 / 消费者被移走）。"
                    + "确认是有意的之后，更新 DisplayClockHostCoverageTests.knownReaderFiles"
            )
        }
        XCTAssertGreaterThanOrEqual(
            readerFiles.count, Self.knownReaderFiles.count,
            "读 \\.displayDate 的文件数（\(readerFiles.count)）少于已知关键消费者数"
                + "（\(Self.knownReaderFiles.count)）：读端集合被悄悄扫空了"
        )
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// Opt-in native rendering/AX probe. Uses this test build's views and synthetic state only.
@MainActor
final class BoundaryUITests: StateTestCase {
    func testCodexFirstQuotaFailureKeepsScannedUsageOutOfProjectionUntilQuotaInfoExists() async throws {
        let store = makeIsolatedConfigStore()
        let home = store.configURL.deletingLastPathComponent().appendingPathComponent("codex", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var config = store.config
        config.providers["codex_chatgpt"] = ProviderConfig(enabled: true, authPath: home.path)
        try store.applyAndSave(config)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let line = """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":123,"cached_input_tokens":23,"output_tokens":45,"reasoning_output_tokens":6}}}}
        """ + "\n"
        try Data(line.utf8).write(to: sessions.appendingPathComponent("fixture.jsonl"))
        let descriptor = FetcherDescriptor(
            id: "codex_chatgpt", displayName: "ChatGPT", kind: .codexChatGpt,
            iconSystemName: "star", accentColor: .chatgpt,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "codex_chatgpt", displayName: "ChatGPT", kind: .codexChatGpt) }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        state.stop()
        defer { state.stop() }
        state.mutateStatus(for: "codex_chatgpt") { $0.state = .failed(message: "synthetic first quota failure", lastSuccess: nil) }
        let target = try XCTUnwrap(state.codexEnrichmentTarget())
        XCTAssertNil(target.model)
        let scanned = await CodexFetcher.loadUsageDetailsAsync(authPath: home.path, model: nil)
        let details = try XCTUnwrap(scanned)
        XCTAssertNil(details.primary)
        XCTAssertNil(details.secondary)
        XCTAssertEqual(details.recentSamples?.count, 1)
        XCTAssertEqual(details.dailyTokenUsage?.reduce(0) { $0 + $1.inputTotal + $1.outputTotal }, 174)
        XCTAssertFalse(state.applyCodexUsageDetails(
            details, providerID: target.providerID, fetchedAt: target.fetchedAt, configurationGeneration: target.generation
        ))
        let first = try XCTUnwrap(state.statuses.first)
        XCTAssertFalse(first.usageProjection(for: first.lastSuccess).clientIDs.contains(ClientID.codex))
        XCTAssertNil(ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.codex])

        // A real fetch result can carry Admin-only data even while the Plan request fails.
        // Any existing QuotaInfo is sufficient; local daily history needs no quota windows.
        let carrier = QuotaInfo(
            models: [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date()
        )
        state.mutateStatus(for: "codex_chatgpt") { $0.state = .failed(message: "synthetic Plan-only failure", lastSuccess: carrier) }
        let cached = await CodexFetcher.loadUsageDetailsAsync(authPath: home.path, model: nil)
        XCTAssertEqual(cached, details, "首次无承载对象时的扫描结果仍可由扫描缓存恢复")
        XCTAssertTrue(state.applyCodexUsageDetails(
            cached, providerID: target.providerID, fetchedAt: target.fetchedAt, configurationGeneration: target.generation
        ))
        let enriched = try XCTUnwrap(state.statuses.first)
        XCTAssertTrue(enriched.usageProjection(for: enriched.lastSuccess).clientIDs.contains(ClientID.codex))
        XCTAssertEqual(ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.codex]?.first?.totalTokens, 174)
    }

    private struct AXNode: Codable {
        let type: String
        let role: String?
        let subrole: String?
        let label: String?
        let title: String?
        let associatedLabels: [String]
        let value: String?
        let placeholder: String?
        let frame: String
        let rawChildCount: Int
        let children: [AXNode]
    }

    private func tree(_ object: Any, depth: Int = 0) -> AXNode? {
        guard depth < 40, let element = object as? NSObject else { return nil }
        // SwiftUI's exported virtual elements need not declare NSAccessibilityProtocol
        // conformance even though they implement its Objective-C selectors.
        func value(_ key: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(key)) else { return nil }
            return element.value(forKey: key)
        }
        let children = value("accessibilityChildren") as? [Any] ?? []
        let associated = (value("accessibilityLabelUIElements") as? [NSObject] ?? [])
            + ((value("accessibilityTitleUIElement") as? NSObject).map { [$0] } ?? [])
        let associatedLabels = associated.flatMap { item in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { key -> String? in
                guard item.responds(to: NSSelectorFromString(key)) else { return nil }
                return item.value(forKey: key) as? String
            }
        }
        return AXNode(
            type: String(describing: type(of: element)),
            role: value("accessibilityRole") as? String,
            subrole: value("accessibilitySubrole") as? String,
            label: value("accessibilityLabel") as? String,
            title: value("accessibilityTitle") as? String,
            associatedLabels: associatedLabels,
            value: value("accessibilityValue").map { String(describing: $0) },
            placeholder: value("accessibilityPlaceholderValue") as? String,
            frame: (value("accessibilityFrame") as? NSValue).map { NSStringFromRect($0.rectValue) } ?? "unknown",
            rawChildCount: children.count,
            children: children.compactMap { tree($0, depth: depth + 1) }
        )
    }

    private func allNodes(_ node: AXNode) -> [AXNode] {
        [node] + node.children.flatMap(allNodes)
    }

    private func assertHistoryStartsAtItsVisibleLeadingEdge(_ node: AXNode, file: StaticString = #filePath, line: UInt = #line) throws {
        let historyViewport = try XCTUnwrap(allNodes(node).last {
            $0.role == "AXScrollArea" && allNodes($0).contains { $0.value == "最近7天使用历史" }
        }, file: file, line: line)
        let viewport = NSRectFromString(historyViewport.frame)
        let firstTexts = allNodes(historyViewport).filter {
            $0.value == "最近7天使用历史" || $0.value == "日期"
        }
        XCTAssertEqual(firstTexts.count, 2, file: file, line: line)
        for text in firstTexts {
            let frame = NSRectFromString(text.frame)
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 0.5,
                "初始横向滚动位置必须完整展示 \(text.value ?? "") 的首字", file: file, line: line)
        }
    }

    @discardableResult
    private func render<V: View>(
        _ view: V, name: String, size: NSSize, directory: URL, verifyHistoryScroll: Bool = false
    ) async throws -> AXNode {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "LLM Monitor current-source boundary probe"
        window.contentView = hosting
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Allow SwiftUI onAppear, pending Settings navigation and AX export to settle.
        try await Task.sleep(nanoseconds: 250_000_000)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func capture(_ filename: String) throws -> AXNode {
            let node = try XCTUnwrap(tree(hosting), "NSHostingView should expose this revision's AX tree")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(node).write(to: directory.appendingPathComponent("\(filename).ax.json"))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(filename).png"))
            return node
        }
        let node = try capture(name)
        if verifyHistoryScroll {
            func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }
            let horizontal = try XCTUnwrap(subviews(hosting).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView else { return false }
                return document.bounds.width > $0.contentView.bounds.width + 1
            }, "窄历史区必须提供可到达最右列的原生横向滚动容器")
            let document = try XCTUnwrap(horizontal.documentView)
            let clip = horizontal.contentView
            clip.scroll(to: NSPoint(x: document.bounds.maxX - clip.bounds.width, y: clip.bounds.minY))
            horizontal.reflectScrolledClipView(clip)
            try await Task.sleep(nanoseconds: 50_000_000)
            hosting.layoutSubtreeIfNeeded()
            let end = try capture("\(name)-scrolled-end")
            let viewport = try XCTUnwrap(allNodes(end).last {
                $0.role == "AXScrollArea" && allNodes($0).contains { $0.value == "最近7天使用历史" }
            })
            let lastColumn = try XCTUnwrap(allNodes(viewport).first { $0.value == "总量" && $0.role == "AXStaticText" })
            XCTAssertGreaterThanOrEqual(NSRectFromString(lastColumn.frame).minX, NSRectFromString(viewport.frame).minX - 0.5,
                "滚到最右后总量列不能越过可视区左边")
            XCTAssertLessThanOrEqual(NSRectFromString(lastColumn.frame).maxX, NSRectFromString(viewport.frame).maxX + 0.5,
                "滚到最右后总量列必须完整可见，不能只让滚动条存在而内容依旧不可达")
        }
        let geometry = "requested=\(NSStringFromSize(size))\nhost=\(NSStringFromRect(hosting.frame))\nfitting=\(NSStringFromSize(hosting.fittingSize))\n"
        try Data(geometry.utf8).write(to: directory.appendingPathComponent("\(name).geometry.txt"))
        return node
    }

    func testCurrentRevisionSettingsBoundaryProbe() async throws {
        guard ProcessInfo.processInfo.environment["LLM_BOUNDARY_UI_PROBE"] == "1" else {
            throw XCTSkip("Opt-in native probe: set LLM_BOUNDARY_UI_PROBE=1")
        }
        let output = ProcessInfo.processInfo.environment["LLM_BOUNDARY_UI_ARTIFACTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("llm-boundary-ui").path
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedMetric = UserDefaults.standard.object(forKey: UsageHistoryMetric.storageKey)
        UserDefaults.standard.set(UsageHistoryMetric.total.rawValue, forKey: UsageHistoryMetric.storageKey)
        defer {
            if let savedMetric { UserDefaults.standard.set(savedMetric, forKey: UsageHistoryMetric.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: UsageHistoryMetric.storageKey) }
        }
        // Request AppKit's AX support for this test process before constructing SwiftUI.
        // Calling the legacy Objective-C selector here avoids requiring a separate trusted AX client.
        let application = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if application.responds(to: enableAX) {
            _ = application.perform(enableAX, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
        let store = makeIsolatedConfigStore()
        let descriptor = FetcherDescriptor(
            id: "antigravity", displayName: "Antigravity", kind: .antigravity,
            iconSystemName: "circle", accentColor: .antigravity,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "antigravity", displayName: "Antigravity", kind: .antigravity) }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        state.stop()
        defer { state.stop() }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).map { offset in
            LocalDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                inputTokens: 123_456, outputTokens: 54_321, cacheReadTokens: 234_567,
                reasoningTokens: 12_345, totalTokens: 424_689, turns: 12, rounds: 345
            )
        }
        state.mutateStatus(for: "antigravity") {
            $0.isEnabled = true
            $0.antigravityLocalUsage = AntigravityLocalUsage(
                today: days[0], dailyTokenUsage: days, scannedAt: Date(), sessionCount: 7,
                eventCount: 345, failedSessionCount: 0, recentSamples: []
            )
        }
        var settings = SettingsView(
            configStore: store, loginItemService: LoginItemService(), state: state, descriptors: [descriptor]
        )
        settings.readNotificationAuthorization = { .unavailable }
        state.pendingSettingsTab = .interface
        let interface = try await render(settings, name: "settings-interface-720", size: NSSize(width: 720, height: 1000), directory: directory)
        let namedControls: [(String, String)] = [
            ("AXRadioGroup", "界面外观"), ("AXPopUpButton", "图标主题"),
            ("AXPopUpButton", "Provider"), ("AXCheckBox", "显示状态圆点"),
            ("AXColorWell", "正常颜色"), ("AXColorWell", "预警颜色"), ("AXColorWell", "异常颜色"),
            ("AXPopUpButton", "形态"), ("AXPopUpButton", "小圆环尺寸"),
            ("AXCheckBox", "内外环独立取色"), ("AXCheckBox", "全屏时不显示"),
        ]
        for (role, name) in namedControls {
            XCTAssertTrue(allNodes(interface).contains {
                $0.role == role && ($0.label == name || $0.title == name || $0.associatedLabels.contains(name))
            }, "当前原生 AX 树必须将 \(name) 关联到可操作的 \(role)，相邻静态文字不足以命名控件")
        }
        state.pendingSettingsTab = .sync
        let sync = try await render(settings, name: "settings-sync-720", size: NSSize(width: 720, height: 900), directory: directory)
        XCTAssertTrue(allNodes(sync).contains { $0.role == "AXCheckBox" && $0.label == "启用多机联动" })
        XCTAssertTrue(allNodes(sync).contains {
            $0.role == "AXRadioGroup" && ($0.label == "联动配置分组" || $0.title == "联动配置分组")
        })
        for name in ["本机名称", "监听端口"] {
            XCTAssertTrue(allNodes(sync).contains { $0.role == "AXTextField" && $0.label == name },
                "Sync 输入框需要字段用途名称，机器名样例或8787占位值不能替代 \(name)")
        }
        let port = try XCTUnwrap(allNodes(sync).first { $0.role == "AXTextField" && $0.label == "监听端口" })
        XCTAssertEqual(port.placeholder, "8787", "字段命名不应修改原有占位提示")
        let client = try XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.antigravity })
        state.pendingSettingsTab = .client(client)
        let clientTree = try await render(settings, name: "settings-client-720", size: NSSize(width: 720, height: 1000), directory: directory, verifyHistoryScroll: true)
        let hostFrame = NSRectFromString(clientTree.frame)
        let panes = clientTree.children.filter { $0.role == "AXScrollArea" }
        XCTAssertEqual(panes.count, 2, "当前设置窗口应导出侧栏和内容区")
        for pane in panes {
            let frame = NSRectFromString(pane.frame)
            XCTAssertGreaterThanOrEqual(frame.minX, hostFrame.minX - 0.5, "历史表不能把侧栏挤出720pt窗口左边")
            XCTAssertLessThanOrEqual(frame.maxX, hostFrame.maxX + 0.5, "历史表不能把右侧内容区撑出720pt窗口右边")
        }
        try assertHistoryStartsAtItsVisibleLeadingEdge(clientTree)
        // Same real row, isolated at the width left by sidebar/pane/section/disclosure padding.
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.antigravity, quotaProviderID: QuotaProviderID.antigravity,
            providerName: "Gemini Models", usageGroupID: "gemini",
            dailyTokenUsage: days.map(UnifiedDailyTokenUsage.init), recentSamples: [], scannedAt: Date()
        )
        let narrow = try await render(
            settings.clientProviderDisclosure(summary, defaultExpanded: true), name: "client-row-420",
            size: NSSize(width: 420, height: 700), directory: directory, verifyHistoryScroll: true
        )
        try assertHistoryStartsAtItsVisibleLeadingEdge(narrow)
        let series = UsageHistorySeriesBuilder.build(
            days: summary.dailyTokenUsage, costByDay: [:], speedByDay: [:], samplesTruncated: false
        )
        for width in [SevenDayUsageChartMetrics.expandedTableWidth, CGFloat(650)] {
            let expanded = try await render(
                SevenDayUsageHistoryView(days: series, scannedAt: nil, isScanning: false, layoutMode: .expanded),
                name: "expanded-table-\(Int(width))", size: NSSize(width: width, height: 650), directory: directory
            )
            let nodes = allNodes(expanded)
            let host = NSRectFromString(expanded.frame)
            let headers = try ["日期", "R/T", "Input", "Cache", "Reason", "Output", "总量"].map { title in
                try XCTUnwrap(nodes.first { $0.role == "AXStaticText" && $0.value == title })
            }
            for header in headers {
                let frame = NSRectFromString(header.frame)
                XCTAssertGreaterThanOrEqual(frame.minX, host.minX - 0.5)
                XCTAssertLessThanOrEqual(frame.maxX, host.maxX + 0.5, "\(width)pt expanded 表七列必须全部可见")
            }
            XCTAssertEqual(NSRectFromString(headers[0].frame).minX, host.minX, accuracy: 0.5)
            XCTAssertEqual(NSRectFromString(headers[6].frame).maxX, host.maxX, accuracy: 0.5,
                "更宽的 expanded 表仍应填满可用宽度")
            let dateValues = Set(series.map { Formatters.formatMonthDay($0.dayStart) })
            let rowFrames = nodes.filter {
                $0.role == "AXStaticText" && dateValues.contains($0.value ?? "")
                    && NSRectFromString($0.frame).maxY < NSRectFromString(headers[0].frame).minY
            }.map { NSRectFromString($0.frame) }.sorted { $0.minY < $1.minY }
            XCTAssertEqual(rowFrames.count, 7, "表格仍需逐行呈现七天数据")
            for (lower, upper) in zip(rowFrames, rowFrames.dropFirst()) {
                XCTAssertLessThanOrEqual(lower.maxY, upper.minY, "行高必须按实际内容测量，不能发生行间重叠")
            }
        }
        var nodeConfig = store.config
        nodeConfig.sync = SyncConfig(enabled: true, hubURL: "http://127.0.0.1:8787", nodeName: "Boundary Node")
        try store.applyAndSave(nodeConfig)
        // AppState remains stopped: this is a UI-only node-role fixture, no Fleet networking.
        let nodePane = try await render(
            SettingsSyncPane(state: state), name: "settings-sync-node-fields", size: NSSize(width: 499, height: 650), directory: directory
        )
        XCTAssertTrue(allNodes(nodePane).contains { $0.role == "AXTextField" && $0.label == "主节点地址" })
        for visible in [false, true] {
            let secret = try await render(
                settings.secretField(label: "Device Key", text: .constant(""), isVisible: .constant(visible), prompt: "从 Bark App 复制"),
                name: "secret-field-visible-\(visible)", size: NSSize(width: 400, height: 90), directory: directory
            )
            XCTAssertTrue(allNodes(secret).contains { $0.role == "AXTextField" && $0.label == "Device Key" },
                "密钥显隐两分支必须把AX名称设置到真实输入节点")
        }
        print("Boundary UI artifacts: \(directory.path)")
    }
}

import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 「命中矩形从哪来」——实测优先、几何兜底，以及矩形顺序与条目顺序必须严格对齐。对应 `resolveRowRects` / `resolveCircleRects` 与 `EdgeDockProjection.orderRowRects`。
final class EdgeDockRowRectSourceTests: EdgeDockTestCase {

    // MARK: - 实测行矩形的命中判定

    func testHitTestUsesMeasuredRectsNotAssumedGeometry() {
        // 人为给每个圆都加同样的漂移，模拟"实测矩形与常量推算对不上"。
        //
        // 守的是**下标↔矩形的对应关系在漂移下不乱**：探针落在哪个矩形里，
        // `circleIndex` 就必须返回那个矩形自己的下标。这条是「hover 上面的圆、
        // 弹出下面那个 provider」那个 bug 的直接对应物。
        //
        // 它**不**能发现"几何层算的位置与视图真实排版对不上"——探针和矩形都出自
        // `circleCenter`，两边会一起漂移。把 `circleCenter` 整体挪 30pt，这条照样绿。
        // 那一层由 `testGeometryMatchesSwiftUILayoutForEveryEdge` 用真实布局量出的
        // 矩形来守；两者合起来才覆盖完整。
        for edge in DockEdge.allCases {
            let circles = measuredCircles(edge: edge, entryCount: 4, drift: 3)
            let dock = EdgeDockGeometry.frame(
                visibleFrame: visible,
                edge: edge,
                size: EdgeDockGeometry.dockSize(entryCount: 4, edge: edge),
                offset: 0.5
            )
            for (index, rect) in circles.enumerated() {
                // 探针 = 未漂移的常量圆心 + 同样的偏移。它落在这个圆的 `midX/midY`
                // 上，所以"命中下标 == index"才真正说明判定用的是实测值。
                let assumed = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: edge, index: index)
                let probe = CGPoint(x: assumed.x + 3, y: assumed.y + 3)
                XCTAssertEqual(rect.midX, probe.x, accuracy: 0.001,
                               "测试自身：探针必须落在实测圆的圆心上")
                XCTAssertEqual(
                    EdgeDockController.circleIndex(at: probe, circles: circles), index,
                    "edge=\(edge) 第\(index)个圆的中心应命中自己"
                )
            }
        }
    }

    /// 行与行之间的缝隙**不命中**任何圆——这是有意的规则，不是待修的缺陷。
    ///
    /// 这里曾有一条"缝隙归属相邻行"的 `rowIndex` 容差，随那个只被测试调用的函数
    /// 一起删掉了。现在判定"只认圆"（`circleIndex`），缝隙落在圆外就返回 nil，
    /// `spec/ui-design.md` 的命中表也是这么写的。钉下来是为了防止哪天有人"顺手"
    /// 把容差加回来——那会让指针在圆与圆之间来回扫时高亮反复跳变，2Hz 轮询会把
    /// 这种抖动放大成看得见的闪烁。
    func testGapBetweenCirclesIsDeliberatelyNotHittable() {
        for edge in DockEdge.allCases {
            let circles = measuredCircles(edge: edge, entryCount: 3)
            let gapMid: CGPoint = edge.isVertical
                ? CGPoint(x: circles[0].midX, y: (circles[0].minY + circles[1].maxY) / 2)
                : CGPoint(x: (circles[0].maxX + circles[1].minX) / 2, y: circles[0].midY)
            XCTAssertNil(
                EdgeDockController.circleIndex(at: gapMid, circles: circles),
                "\(edge.rawValue) 两个圆之间的缝隙应当不命中（判定只认圆）"
            )
            // 对照组：圆心必须命中自己——上面那条不是"整个判定坏了"。
            let firstCenter = CGPoint(x: circles[0].midX, y: circles[0].midY)
            XCTAssertEqual(
                EdgeDockController.circleIndex(at: firstCenter, circles: circles),
                0,
                "对照组：第 0 个圆的圆心仍应命中"
            )
        }
    }

    // MARK: - 行下标与 provider 的对应关系

    //

    // 这一组是「hover minimax、弹出 DeepSeek」那个 bug 的钉死。

    // 命中下标会被拿去反查 entries[index].id 决定 popover 显示谁，所以

    func testOrderRowRectsKeysOutputByEntryOrderNotReportOrder() {
        // 上报是字典（无序），输出必须按 entries 顺序重建，逐槽对上自己的 id。
        let entries = makeEntries(["minimax", "deepseek", "glm", "chatgpt"])
        let reported = rowRectsByID(entries, drift: 2)
        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        XCTAssertEqual(ordered.count, entries.count, "输出长度必须与条目数一致")
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(
                ordered[index], reported[entry.id],
                "第\(index)槽必须是 \(entry.id) 自己的矩形"
            )
        }
    }

    func testOrderRowRectsKeepsLaterSlotsAlignedWhenOneRowMissing() {
        // 少一行的正确处理是「留一个永不命中的坑」，不是跳过——跳过会让后面整体前移，
        // 变成另一种更隐蔽的下标错位。
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        var reported = rowRectsByID(entries)
        reported.removeValue(forKey: "deepseek")

        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        XCTAssertEqual(ordered.count, 3, "缺一行也不能少一槽")
        XCTAssertEqual(ordered[0], reported["minimax"], "minimax 槽不受影响")
        XCTAssertEqual(ordered[1], EdgeDockProjection.unmeasuredRow, "缺测的行填不可命中的占位")
        XCTAssertEqual(ordered[2], reported["glm"], "glm 槽不能前移到下标 1")
    }

    func testUnmeasuredRowIsNeverHittable() {
        // 占位矩形必须在任何真实鼠标位置之外，且自身不命中。
        //
        // 断言走 `circleIndex`——那是真正驱动命中的判定。
        let circles = measuredRows(edge: .right, entryCount: 2) + [EdgeDockProjection.unmeasuredRow]
        XCTAssertNil(
            EdgeDockController.circleIndex(at: CGPoint(x: 1900, y: 400), circles: circles),
            "真实屏幕点不该命中占位行"
        )
        XCTAssertNil(
            EdgeDockController.circleIndex(at: .zero, circles: circles),
            "原点也不该命中占位行"
        )
    }

    func testHoveringEachRowResolvesToThatSameProvider() {
        // 端到端钉死用户报的那个症状：对第 i 个圆取样，命中下标必须是 i，
        // 于是 popover 反查到的就是第 i 个 provider。
        let entries = makeEntries(["minimax", "deepseek", "glm", "chatgpt"])
        let reported = rowRectsByID(entries, drift: 3)
        let measured = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        for (index, entry) in entries.enumerated() {
            let rect = measured[index]
            // 取样点必须在圆内：行矩形比圆大（含数值文字那一段），而命中只认圆，
            // 所以这里取圆心，而不是行中心——否则测的是一条不存在的规则。
            for probe in [CGPoint(x: rect.midX, y: rect.midY),
                          CGPoint(x: rect.midX, y: rect.midY - EdgeDockGeometry.diameter / 4)] {
                let hit = EdgeDockController.circleIndex(at: probe, circles: measured)
                XCTAssertEqual(
                    hit, index,
                    "hover \(entry.id) 的圆（下标\(index)）却命中 \(String(describing: hit))"
                )
            }
        }
    }

    func testHoverOrderIsStableUnderRectKeyReordering() {
        // 上报顺序一变（SwiftUI 不保证 reduce 顺序），命中结果必须完全不变。
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let rects = measuredRows(edge: .right, entryCount: 3, drift: 1)
        let forward = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), rects))
        // 反着配一遍：id 与矩形故意错位配对后再交给重排，看结果是否仍按 id 归位。
        let shuffled = Dictionary(uniqueKeysWithValues: zip(entries.reversed().map(\.id), rects))

        let a = EdgeDockProjection.orderRowRects(entries: entries, reported: forward)
        let b = EdgeDockProjection.orderRowRects(entries: entries, reported: shuffled)
        XCTAssertEqual(a.count, b.count)
        // forward 与 shuffled 是不同数据，只断言"都能按 id 找到自己的矩形"。
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(b[index], shuffled[entry.id], "第\(index)槽应对应 \(entry.id) 自己的矩形")
            XCTAssertEqual(
                EdgeDockController.circleIndex(
                    at: CGPoint(x: b[index].midX, y: b[index].midY), circles: b
                ),
                index,
                "重排后 hover \(entry.id) 仍应命中下标\(index)"
            )
        }
    }

    // MARK: - 命中矩形选取：实测不可用时必须还能命中

    //

    // 这组是「hover 和拖拽同时失能」那个回归的钉死。命中一旦恒为 nil，

    // `captureMouse()` 就不执行，`ignoresMouseEvents` 一直是 true，

    // 于是 hover 无效、按下也收不到 —— 表现为两个功能一起坏。

    func testGeometryFallbackKeepsEveryRowHittable() {
        // 一条实测矩形都没有时，必须退回几何推算，且**每一个圆**都还能命中自己。
        //
        // 断言走 `resolveCircleRects` + `circleIndex`——那才是真正驱动命中的那条
        // 路径（行矩形如今只用于 popover 纵向锚点，不参与命中）。
        for edge in DockEdge.allCases {
            for count in 1...8 {
                let entries = makeEntries((0..<count).map { "p\($0)" })
                let frame = panelFrame(edge: edge, entryCount: count)
                let resolved = EdgeDockController.resolveCircleRects(
                    entries: entries, measured: [:], panelFrame: frame, edge: edge, slack: 8
                )
                XCTAssertFalse(resolved.usedMeasured, "没有实测数据却声称用了实测")
                XCTAssertEqual(resolved.circles.count, count)
                // 用 firstRange 而不是直接下标：兜底一旦返回空数组，这里要报出清晰的
                // 断言失败，而不是先崩在 "Index out of range" 上把真正的原因盖掉。
                guard resolved.circles.first != nil else {
                    XCTFail("edge=\(edge) count=\(count) 兜底返回了空圆数组，hover 会彻底失能")
                    continue
                }
                for index in 0..<count {
                    let circle = resolved.circles[index]
                    XCTAssertEqual(
                        EdgeDockController.circleIndex(
                            at: CGPoint(x: circle.midX, y: circle.midY), circles: resolved.circles
                        ),
                        index,
                        "edge=\(edge) count=\(count) 第\(index)个圆兜底后必须还能命中"
                    )
                }
            }
        }
    }

    func testGeometryFallbackRowsFollowCircleOrder() {
        // 兜底行的中心必须与 `circleCenter` 同序，否则下标 i 指向的不是第 i 个圆。
        for edge in DockEdge.allCases {
            let count = 5
            let frame = panelFrame(edge: edge, entryCount: count)
            let rows = EdgeDockGeometry.rowRects(dockFrame: frame, edge: edge, entryCount: count)
            for index in 0..<count {
                let expected = EdgeDockGeometry.rowCenter(
                    dockFrame: frame, edge: edge, index: index
                )
                let actual = CGPoint(x: rows[index].midX, y: rows[index].midY)
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, "edge=\(edge) 第\(index)行 x")
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, "edge=\(edge) 第\(index)行 y")
            }
        }
    }

    func testGeometryFallbackWithZeroEntriesProducesNoRows() {
        for edge in DockEdge.allCases {
            let frame = panelFrame(edge: edge, entryCount: 0)
            let resolved = EdgeDockController.resolveRowRects(
                entries: [], measured: [:], panelFrame: frame, edge: edge, slack: 8
            )
            XCTAssertTrue(resolved.rows.isEmpty, "没有 provider 时不该造出幽灵行")
            XCTAssertFalse(resolved.usedMeasured)
        }
    }

    func testResolveRowRectsFallsBackWhenMeasurementIncomplete() {
        // 少一行的实测：整体退回几何，不能让后面的行错位顶上来。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let partial = rowRectsByID(entries, edge: edge)
            .filter { $0.key != "deepseek" }

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: partial, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertFalse(resolved.usedMeasured, "实测不完整必须退回")
        XCTAssertEqual(
            resolved.rows, EdgeDockGeometry.rowRects(
                dockFrame: frame, edge: edge, entryCount: 3
            ),
            "退回的结果应与几何推算完全一致"
        )
    }

    func testResolveRowRectsFallsBackWhenConvertedRectsAreOffscreen() {
        // 坐标系换算错到窗口外：宁可偏差也要能命中，不能整列都指空。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let bogus = rowRectsByID(entries, edge: edge)
            .mapValues { CGRect(x: $0.minX + 5_000, y: $0.minY + 5_000, width: $0.width, height: $0.height) }

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: bogus, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertFalse(resolved.usedMeasured, "矩形全在窗口外说明换算错了，必须退回")
        XCTAssertEqual(
            resolved.rows.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) },
            true,
            "兜底后窗口中心必须仍落在某一行里"
        )
    }

    func testResolveRowRectsUsesMeasurementWhenUsable() {
        // 正常路径：实测可用就用实测，不退回。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let good = rowRectsByID(entries, edge: edge, drift: 2)

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: good, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertTrue(resolved.usedMeasured, "实测可用时不该退回")
        XCTAssertEqual(
            resolved.rows, EdgeDockProjection.orderRowRects(entries: entries, reported: good),
            "实测路径应原样按条目顺序返回"
        )
    }

    /// 堆叠轴上的步进必须**分朝向**：完整形态下竖排是 `rowStep`(70)、横排是
    /// `columnStep`(54)，两者差 16pt（数值文字在圆的**下方**，横排列宽不吃行高）。
    ///
    /// 这条是给一次真实回归写的：把 `circleCenter` 重构成"共用一个 step 局部量"时，
    /// 顺手让横排也用了 `rowStep`，于是横排第 1 个及之后的圆整体外移 16pt——兜底
    /// 一旦被用到就会命中错误的 provider。原有测试全绿：它们断言的是"第 i 个圆中心
    /// 落在第 i 行里"这类**关系**，而整列一起平移不破坏任何关系。只有把步进本身
    /// 钉成常量才抓得住。
    func testCirclePitchFollowsEdgeDirection() {
        for edge in DockEdge.allCases {
            let frame = makeDockFrame(edge: edge, entryCount: 4)
            let circles = EdgeDockGeometry.circleRects(dockFrame: frame, edge: edge, entryCount: 4)
            let expected = edge.isVertical ? EdgeDockGeometry.rowStep : EdgeDockGeometry.columnStep
            for index in 1..<circles.count {
                let delta = edge.isVertical
                    ? abs(circles[index].midY - circles[index - 1].midY)
                    : abs(circles[index].midX - circles[index - 1].midX)
                XCTAssertEqual(
                    delta, expected, accuracy: 0.001,
                    "\(edge.rawValue) 第\(index)个圆与前一个的间距应是 \(expected)，实际 \(delta)"
                )
            }
            // 顺带钉住这条轴向关系本身：完整形态的列步进比行步进小一个 spacing
            // （行高 54 − 圆径 38 = labelSpacing + labelHeight = 16）。
            if !edge.isVertical {
                XCTAssertEqual(
                    EdgeDockGeometry.rowStep - EdgeDockGeometry.columnStep,
                    EdgeDockGeometry.labelSpacing + EdgeDockGeometry.labelHeight,
                    accuracy: 0.001,
                    "竖排与横排步进之差应正好是「数值文字 + 间距」"
                )
            }
        }
    }

    // MARK: - 兜底路径必须感知形态

    /// 简版 dock 的兜底矩形必须按**简版**常量算，而不是完整形态的。
    ///
    /// 这是本分支修掉的一个真实缺陷：`circleRects` / `rowRects` 曾经无条件使用
    /// `diameter`(38) / `rowStep`(70) / `padding`(16)，而简版的真实值是 7 / 15 / 7。
    /// 后果不是"差一点"，而是圆心整体偏出约 24pt，hover 高亮到隔壁那个 provider；
    /// 兜底还会在 `startHoverPoll()` 的首次同步探测里被用到（那时视图还没上报任何
    /// 矩形），所以这不是只在测量失效时才出现的边角情况。
    func testCompactFallbackGeometryUsesCompactConstantsNotFullOnes() {
        for edge in DockEdge.allCases {
            let entryCount = 4
            let compactFrame = EdgeDockGeometry.frame(
                visibleFrame: visible,
                edge: edge,
                size: EdgeDockGeometry.dockSize(
                    entryCount: entryCount, edge: edge, appearance: .compact
                ),
                offset: 0.5
            )
            let fullFrame = makeDockFrame(edge: edge, entryCount: entryCount)

            let compactCircles = EdgeDockGeometry.circleRects(
                dockFrame: compactFrame, edge: edge, entryCount: entryCount, appearance: .compact
            )
            let compactRows = EdgeDockGeometry.rowRects(
                dockFrame: compactFrame, edge: edge, entryCount: entryCount, appearance: .compact
            )

            XCTAssertEqual(compactCircles.count, entryCount)
            XCTAssertEqual(compactRows.count, entryCount)
            XCTAssertTrue(
                compactCircles.allSatisfy { $0.width == EdgeDockGeometry.compactDiameter },
                "\(edge.rawValue) 简版兜底圆必须是 \(EdgeDockGeometry.compactDiameter)pt，实际 \(compactCircles.map(\.width))"
            )
            // 步进必须等于简版行距：相邻两行的间距错了，命中就会整列错位。
            let step = edge.isVertical
                ? abs(compactCircles[1].midY - compactCircles[0].midY)
                : abs(compactCircles[1].midX - compactCircles[0].midX)
            XCTAssertEqual(
                step, EdgeDockGeometry.compactRowStep, accuracy: 0.001,
                "\(edge.rawValue) 简版兜底的行距必须是 compactRowStep"
            )
            // 与完整形态的兜底刻意不同——相等就说明 appearance 根本没被传下去。
            let fullCircles = EdgeDockGeometry.circleRects(
                dockFrame: fullFrame, edge: edge, entryCount: entryCount
            )
            XCTAssertNotEqual(
                compactCircles.map(\.width), fullCircles.map(\.width),
                "\(edge.rawValue) 简版兜底不能与完整形态一样"
            )
        }
    }

    /// 简版兜底的圆心必须落在窗口内边距之内（`compactPadding`），而不是完整形态的
    /// `padding`——后者会把第一行推离真实位置 9pt。
    func testCompactFallbackCentersRespectCompactPadding() {
        for edge in DockEdge.allCases {
            let frame = EdgeDockGeometry.frame(
                visibleFrame: visible,
                edge: edge,
                size: EdgeDockGeometry.dockSize(entryCount: 3, edge: edge, appearance: .compact),
                offset: 0.5
            )
            let first = EdgeDockGeometry.circleCenter(
                dockFrame: frame, edge: edge, index: 0, appearance: .compact
            )
            let lead = edge.isVertical
                ? frame.maxY - first.y
                : first.x - frame.minX
            XCTAssertEqual(
                lead,
                EdgeDockGeometry.compactPadding + EdgeDockGeometry.compactDiameter / 2,
                accuracy: 0.001,
                "\(edge.rawValue) 简版第 0 行的起始内边距必须是 compactPadding"
            )
        }
    }

    /// `resolveCircleRects` 必须把 appearance 传进兜底。
    ///
    /// 这一层是"控制器 → 几何"的接缝：`resolveCircleRects` 曾经是
    /// `nonisolated` 纯函数且**没有** appearance 参数，于是无论调用方处于什么形态，
    /// 它都去调完整形态的 `circleRects`。
    func testResolveCircleRectsPropagatesAppearanceIntoTheFallback() {
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek"])
        let frame = EdgeDockGeometry.frame(
            visibleFrame: visible,
            edge: edge,
            size: EdgeDockGeometry.dockSize(entryCount: 2, edge: edge, appearance: .compact),
            offset: 0.5
        )
        // measured 传空 → 必然走兜底。
        let resolved = EdgeDockController.resolveCircleRects(
            entries: entries, measured: [:], panelFrame: frame, edge: edge,
            slack: 8, appearance: .compact
        )
        XCTAssertFalse(resolved.usedMeasured, "没有实测矩形时必须走兜底")
        XCTAssertTrue(
            resolved.circles.allSatisfy { $0.width == EdgeDockGeometry.compactDiameter },
            "兜底必须已经是简版尺寸，实际 \(resolved.circles.map(\.width))"
        )
        // 兜底位置下，指针落在"简版真实圆心"上必须能命中第 0 行。
        let center = EdgeDockGeometry.circleCenter(
            dockFrame: frame, edge: edge, index: 0, appearance: .compact
        )
        XCTAssertEqual(
            EdgeDockController.circleIndex(
                at: center, circles: resolved.circles, minimumRadius: EdgeDockGeometry.compactRowStep / 2
            ),
            0,
            "简版真实圆心必须命中第 0 个圆"
        )
    }
}

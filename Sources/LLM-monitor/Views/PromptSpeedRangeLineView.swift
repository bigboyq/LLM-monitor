import SwiftUI

/// Prompt 速度分布的紧凑范围线。scaleMaximum 由当前菜单的全部本地行共享，
/// 使展开后的模型间能直接比较；无效 / 非有限读数不会进入坐标映射。
struct PromptSpeedRangeLineView: View {
    let statistics: PromptSpeedStatistics
    let scaleMaximum: Double?

    private var minimum: Double? { finitePositiveOrZero(statistics.minimum) }
    private var maximum: Double? { finitePositiveOrZero(statistics.maximum) }
    private var p50: Double? { finitePositiveOrZero(statistics.p50) }
    private var latest: Double? { finitePositiveOrZero(statistics.latest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let minimum, let maximum, statistics.validPromptCount > 0 {
                GeometryReader { geometry in
                    let width = max(geometry.size.width - 12, 1)
                    let xMin = x(for: minimum, width: width)
                    let xMax = x(for: maximum, width: width)
                    let xP50 = p50.map { x(for: $0, width: width) }
                    let xLatest = latest.map { x(for: $0, width: width) }

                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                            .frame(width: width, height: 2)
                            .position(x: width / 2, y: 24)
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(xMax - xMin, 2), height: 3)
                            .position(x: (xMin + xMax) / 2, y: 24)

                        Circle().stroke(Color.secondary, lineWidth: 1.2)
                            .frame(width: 6, height: 6).position(x: xMin, y: 20)
                        Circle().stroke(Color.secondary, lineWidth: 1.2)
                            .frame(width: 6, height: 6).position(x: xMax, y: 28)
                        if let xP50 {
                            Circle().fill(Color.accentColor)
                                .frame(width: 7, height: 7).position(x: xP50, y: 20)
                        }
                        if let xLatest {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primaryLabel)
                                .frame(width: 3, height: 8).position(x: xLatest, y: 28)
                        }

                        PromptSpeedLabelPairLayout(markerPositions: [xMin, xP50 ?? xMin]) {
                            Text("min")
                            Text(":")
                            Text(" \(Self.speedValue(minimum))")
                            Text("P50")
                            Text(":")
                            Text(" \(Self.speedValue(p50))")
                        }
                        .font(MenuTypography.hint.monospacedDigit())
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: width, height: 12, alignment: .topLeading)

                        if let xLatest {
                            PromptSpeedLabelPairLayout(markerPositions: [xLatest, xMax]) {
                                Text("最近")
                                Text(":")
                                Text(" \(Self.speedValue(latest))")
                                Text("max")
                                Text(":")
                                Text(" \(Self.speedValue(maximum))")
                            }
                            .font(MenuTypography.hint.monospacedDigit())
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: width, height: 12, alignment: .topLeading)
                            .position(x: width / 2, y: 42)
                        } else {
                            PromptSpeedLabelPairLayout(markerPositions: [xMax, xMax]) {
                                Text("最近")
                                Text(":")
                                Text(" —")
                                Text("max")
                                Text(":")
                                Text(" \(Self.speedValue(maximum))")
                            }
                            .font(MenuTypography.hint.monospacedDigit())
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: width, height: 12, alignment: .topLeading)
                            .position(x: width / 2, y: 42)
                        }
                    }
                    .frame(width: width, height: 48, alignment: .topLeading)
                    .padding(.horizontal, 6)
                }
                .frame(height: 48)
                .help("按 Prompt 统计的速度范围；圆点为 P50，竖线为最近一次 Prompt，速度单位为 tok/s。有效 Prompt / 今日已记录 Prompt：\(statistics.validPromptCount)/\(statistics.totalPromptCount)。任一调用缺失有效时长时，整个 Prompt 不参与速度分布。最近 Prompt 缺失时长显示 —，不回填旧值。")
            } else {
                Text("速度范围 —")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
                    .help("没有可用的完整 Prompt 速度样本；速度单位为 tok/s。有效 Prompt / 今日已记录 Prompt：\(statistics.validPromptCount)/\(statistics.totalPromptCount)。")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("速度范围，单位 tok/s：最小 \(Self.speedValue(minimum))，P50 \(Self.speedValue(p50))，最大 \(Self.speedValue(maximum))，最近 Prompt \(Self.speedValue(latest))，有效 Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)")
    }

    static func speedText(_ value: Double?) -> String {
        "\(speedValue(value)) tok/s"
    }

    private static func speedValue(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return QuotaWindowUsageSection.speedText(value)
    }

    private func finitePositiveOrZero(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        PromptSpeedRangeGeometry.x(
            for: value,
            scaleMaximum: scaleMaximum,
            fallbackMaximum: maximum,
            width: width
        )
    }
}

/// Places two prefix/colon/value labels so each colon tracks its actual marker.
/// If labels collide, it chooses the smallest in-bounds shift; marker coordinates never move.
struct PromptSpeedLabelPairLayout: Layout {
    let markerPositions: [CGFloat]
    var gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 6 else { return }

        let availableWidth = max(bounds.width, 0)
        let desiredSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let effectiveGap = min(gap, availableWidth)
        let desiredLabelWidths = [
            desiredSizes[0].width + desiredSizes[1].width + desiredSizes[2].width,
            desiredSizes[3].width + desiredSizes[4].width + desiredSizes[5].width
        ]
        let totalWidth = desiredLabelWidths[0] + desiredLabelWidths[1] + effectiveGap
        let labelWidthLimit = totalWidth > availableWidth
            ? max((availableWidth - effectiveGap) / 2, 0)
            : nil
        var sizes: [CGSize] = []
        var proposals: [CGFloat] = []
        for labelIndex in 0..<2 {
            let start = labelIndex * 3
            let naturalWidth = desiredLabelWidths[labelIndex]
            let scale = labelWidthLimit.map { naturalWidth > 0 ? min($0 / naturalWidth, 1) : 1 } ?? 1
            for componentIndex in 0..<3 {
                let index = start + componentIndex
                let proposedWidth = desiredSizes[index].width * scale
                proposals.append(proposedWidth)
                sizes.append(subviews[index].sizeThatFits(
                    ProposedViewSize(width: proposedWidth, height: bounds.height)
                ))
            }
        }
        let firstAnchor = markerPositions.indices.contains(0) ? markerPositions[0] : 0
        let secondAnchor = markerPositions.indices.contains(1) ? markerPositions[1] : firstAnchor
        let firstWidth = sizes[0].width + sizes[1].width + sizes[2].width
        let secondWidth = sizes[3].width + sizes[4].width + sizes[5].width
        let firstColonOffset = PromptSpeedLabelPlacement.colonOffset(
            prefixWidth: sizes[0].width,
            colonWidth: sizes[1].width
        )
        let secondColonOffset = PromptSpeedLabelPlacement.colonOffset(
            prefixWidth: sizes[3].width,
            colonWidth: sizes[4].width
        )
        let origins = PromptSpeedLabelPlacement.resolve(
            firstAnchor: firstAnchor,
            secondAnchor: secondAnchor,
            firstColonOffset: firstColonOffset,
            secondColonOffset: secondColonOffset,
            firstWidth: firstWidth,
            secondWidth: secondWidth,
            gap: effectiveGap,
            containerWidth: availableWidth
        )

        for index in 0..<6 {
            let labelIndex = index / 3
            let componentOffset = index % 3
            let previousComponentWidths = (0..<componentOffset).reduce(CGFloat.zero) { partial, offset in
                partial + sizes[labelIndex * 3 + offset].width
            }
            let labelOrigin = origins[labelIndex] + previousComponentWidths
            subviews[index].place(
                at: CGPoint(x: bounds.minX + labelOrigin, y: bounds.minY),
                proposal: ProposedViewSize(width: proposals[index], height: bounds.height)
            )
        }
    }
}

/// Pure geometry shared by the SwiftUI layout and layout regression tests.
enum PromptSpeedLabelPlacement {
    static func colonOffset(prefixWidth: CGFloat, colonWidth: CGFloat) -> CGFloat {
        max(prefixWidth, 0) + max(colonWidth, 0) / 2
    }

    static func resolve(
        firstAnchor: CGFloat,
        secondAnchor: CGFloat,
        firstColonOffset: CGFloat,
        secondColonOffset: CGFloat,
        firstWidth: CGFloat,
        secondWidth: CGFloat,
        gap: CGFloat,
        containerWidth: CGFloat
    ) -> [CGFloat] {
        let width = max(containerWidth, 0)
        let firstLabelWidth = min(max(firstWidth, 0), width)
        let secondLabelWidth = min(max(secondWidth, 0), width)
        let spacing = max(gap, 0)
        let firstMaximum = max(width - firstLabelWidth, 0)
        let secondMaximum = max(width - secondLabelWidth, 0)
        let preferredFirst = min(max(firstAnchor - firstColonOffset, 0), firstMaximum)
        let preferredSecond = min(max(secondAnchor - secondColonOffset, 0), secondMaximum)
        guard preferredFirst + firstLabelWidth + spacing > preferredSecond else {
            return [preferredFirst, preferredSecond]
        }

        let keepFirstSecond = preferredFirst + firstLabelWidth + spacing
        let canKeepFirst = keepFirstSecond <= secondMaximum
        let keepSecondFirst = preferredSecond - firstLabelWidth - spacing
        let canKeepSecond = keepSecondFirst >= 0
        if canKeepFirst && canKeepSecond {
            let firstShift = abs(keepFirstSecond - preferredSecond)
            let secondShift = abs(preferredFirst - keepSecondFirst)
            return firstShift <= secondShift
                ? [preferredFirst, keepFirstSecond]
                : [keepSecondFirst, preferredSecond]
        }
        if canKeepFirst { return [preferredFirst, keepFirstSecond] }
        if canKeepSecond { return [keepSecondFirst, preferredSecond] }

        // Both anchors are displaced only when neither label can keep its preferred start.
        let firstStart = min(
            max((preferredFirst + preferredSecond - firstLabelWidth - spacing) / 2, 0),
            max(width - firstLabelWidth - spacing - secondLabelWidth, 0)
        )
        return [firstStart, firstStart + firstLabelWidth + spacing]
    }
}

enum PromptSpeedRangeGeometry {
    static func x(for value: Double, scaleMaximum: Double?, fallbackMaximum: Double?, width: CGFloat) -> CGFloat {
        let bound = scaleMaximum.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? fallbackMaximum.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? 0
        guard bound > 0, value.isFinite else { return max(width, 0) / 2 }
        return min(max(CGFloat(value / bound) * max(width, 0), 0), max(width, 0))
    }
}

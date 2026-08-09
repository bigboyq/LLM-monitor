import SwiftUI

/// 单列堆叠柱图片段。`StackedTokenBar` 用一组 segment 自下而上堆叠。
struct TokenBarSegment {
    let height: CGFloat
    let color: Color
}

/// 单列堆叠柱图（input+cache / output+reasoning 各一列），4 类 provider 7-day chart 共用。
struct StackedTokenBar: View {
    let segments: [TokenBarSegment]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 1) {
                Spacer(minLength: 0)
                ForEach(Array(segments.reversed().enumerated()), id: \.offset) { _, segment in
                    if segment.height > 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(segment.color)
                            .frame(height: max(2, segment.height))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// token 数值 → 视觉权重的非线性缩放（pow 0.3 保留大额差异同时让长尾可读）。
enum TokenChartScale {
    /// 0.3 在保留大额差异的同时，让输出、推理等长尾分段仍有可读高度。
    static let exponent = 0.3

    static func weight(for value: Int) -> Double {
        pow(Double(max(value, 0)), exponent)
    }
}

import SwiftUI
import AppKit

extension Color {
    /// 玻璃材质上仍保持清晰的系统正文色，不依赖 vibrancy 自动混合。
    static let primaryLabel = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)

    static let minimaxBrand = Color(red: 0.76, green: 0.06, blue: 0.82)
    static let chatgptBrand = Color(red: 0.01, green: 0.70, blue: 0.28)
    static let antigravityGemini = Color(red: 0.10, green: 0.49, blue: 0.96)
    static let antigravityClaude = Color(red: 0.86, green: 0.45, blue: 0.16)
    /// 智谱 GLM 品牌色（靛蓝，区别于 Antigravity 的宝石蓝与 minimax 的品红）
    static let glmBrand = Color(red: 0.32, green: 0.36, blue: 0.92)
}

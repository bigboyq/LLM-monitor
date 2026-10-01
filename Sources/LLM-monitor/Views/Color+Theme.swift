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

    /// 统一预警语义色：深浅模式下均符合 WCAG 2.1 AA 对比度要求，且与 StatusIndicator 的 warning (orange) 对齐，
    /// 解决系统 Color.yellow 在浅色背景下对比度不足 2:1 的问题。
    static let warningTint = Color(nsColor: .systemOrange)

    /// 统一"健康"语义色。SwiftUI 的 `.green` 是**固定色**：不随外观变化，
    /// 同一个值在深色卡片上只是偏亮，在**浅色卡片上则是刺眼的亮绿**——白底亮绿
    /// 的对比度看着够，但它的高饱和度会在一行里跳出来把整张卡片的注意力抢走。
    /// `systemGreen` 有专门的浅色/深色两套变体（浅色模式自动压暗、加深），
    /// 和 `warningTint` 同一套做法。
    static let healthyTint = Color(nsColor: .systemGreen)
}


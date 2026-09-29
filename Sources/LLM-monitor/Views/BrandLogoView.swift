import SwiftUI
import AppKit

/// 品牌图标资源。Provider 使用关联值；OpenCode 是共享数据源，不属于 ProviderKind。
enum BrandLogoAsset: Hashable, Sendable {
    case provider(ProviderKind)
    case opencode

    fileprivate var cacheKey: String {
        switch self {
        case .provider(let kind): return kind.rawValue
        case .opencode: return "opencode"
        }
    }

}

/// Provider 与本地数据源的真实品牌标志。资源统一按小尺寸展示，不再用无关的 SF Symbol 代替。
struct BrandLogoView: View {
    /// 菜单卡片 / 设置页的常规边长（pt）。
    static let defaultSize: CGFloat = 18

    let asset: BrandLogoAsset
    /// 实际绘制边长（pt）。
    ///
    /// **必须由视图自己消费掉这个尺寸**，不能指望调用方在外层套一个
    /// `.frame(width:height:)` 就变小：SwiftUI 的 `frame` 只是把尺寸当作
    /// *proposal* 递给子视图，子视图若自己带固定 `frame`（见 `body` 末尾），
    /// 就会按自己的尺寸返回，外层那个 frame 只是把这块更大的内容**居中摆放**——
    /// 既不缩放也不裁剪。dock 的中心图标曾经就是这样把 6pt 的意图画成 18pt、
    /// 压到内环上的（见 `EdgeDockGeometry.iconSize`）。
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(kind: ProviderKind, size: CGFloat = BrandLogoView.defaultSize) {
        asset = .provider(kind)
        self.size = size
    }

    init(asset: BrandLogoAsset, size: CGFloat = BrandLogoView.defaultSize) {
        self.asset = asset
        self.size = size
    }

    private final class ImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: NSImage] = [:]
        private var missingAssets: Set<String> = []

        func image(for asset: BrandLogoAsset, darkMode: Bool) -> NSImage? {
            let appearanceKey = asset == .opencode ? (darkMode ? "dark" : "light") : "default"
            let key = "\(asset.cacheKey)-\(appearanceKey)"
            lock.lock()
            defer { lock.unlock() }
            if let image = images[key] { return image }
            if missingAssets.contains(key) { return nil }

            guard let image = Self.loadImage(for: asset, darkMode: darkMode) else {
                missingAssets.insert(key)
                return nil
            }
            images[key] = image
            return image
        }

        private static func loadImage(for asset: BrandLogoAsset, darkMode: Bool) -> NSImage? {
            switch asset {
            case .opencode:
                return loadSvg(darkMode ? "opencode-dark" : "opencode-light")
            case .provider(let kind):
                switch kind {
                case .minimaxTokenPlan:
                    return loadMinimaxLogo()
                case .codexChatGpt:
                    return loadSvg("openai")
                case .antigravity:
                    return loadSvg("antigravity")
                case .deepseek:
                    return loadSvg("deepseek")
                case .glmCodingPlan:
                    // glm-mini：官方 mini 版单色横向标志（34×27，纯白路径），
                    // 取代原先带深色底的方形徽章——小尺寸（尤其 dock 内 8pt）下
                    // 徽章里的细节会糊成一片。单色 asset 必须走 template 渲染，
                    // 否则浅色模式下白路径在浅色卡片上不可见。
                    return loadSvg("glm-mini")
                }
            }
        }

        private static func loadSvg(_ name: String) -> NSImage? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }

        /// 缺少 bundled 资源时保留可识别的兜底符号，避免整个位置变空。
        static func fallbackSymbol(for asset: BrandLogoAsset) -> String? {
            switch asset {
            case .opencode: return "terminal"
            case .provider(.glmCodingPlan): return "chevron.left.forwardslash.chevron.right"
            case .provider(.deepseek): return "wave.3.right"
            case .provider: return nil
            }
        }

        /// 官网 logo 是横向的“图形 + MiniMax”组合标志；卡片标题已经有文字，
        /// 因此只裁出左侧图形，避免把完整字标压缩进小空间。
        private static func loadMinimaxLogo() -> NSImage? {
            guard let url = Bundle.module.url(forResource: "minimax-official", withExtension: "webp"),
                  let source = NSImage(contentsOf: url),
                  let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }

            let cropWidth = min(cgImage.width, Int(Double(cgImage.height) * 1.25))
            let cropRect = CGRect(x: 0, y: 0, width: cropWidth, height: cgImage.height)
            guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
            return NSImage(
                cgImage: cropped,
                size: NSSize(width: cropWidth, height: cgImage.height)
            )
        }
    }

    private static let imageCache = ImageCache()

    /// 单色 asset 走 template 渲染（跟随 `primaryLabel` 前景色，明暗外观都可读）；
    /// 带底色/配色的 asset 保持 original。
    private var rendersAsTemplate: Bool {
        switch asset {
        case .provider(.codexChatGpt), .provider(.glmCodingPlan):
            return true
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if let image = Self.imageCache.image(for: asset, darkMode: colorScheme == .dark) {
                if rendersAsTemplate {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Color.primaryLabel)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            } else if let symbol = Self.ImageCache.fallbackSymbol(for: asset) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.72, weight: .medium))
                    .frame(width: size, height: size)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

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
    let asset: BrandLogoAsset

    @Environment(\.colorScheme) private var colorScheme

    init(kind: ProviderKind) {
        asset = .provider(kind)
    }

    init(asset: BrandLogoAsset) {
        self.asset = asset
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
                    return loadSvg("glm")
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

    var body: some View {
        Group {
            if let image = Self.imageCache.image(for: asset, darkMode: colorScheme == .dark) {
                if asset == .provider(.codexChatGpt) {
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
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
            } else {
                Color.clear
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

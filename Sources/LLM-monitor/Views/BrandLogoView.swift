import SwiftUI
import AppKit

/// provider 的真实品牌标志。资源统一按小尺寸展示，不再用无关的 SF Symbol 代替。
struct BrandLogoView: View {
    let kind: ProviderKind

    private final class ImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: NSImage] = [:]
        private var missingAssets: Set<String> = []

        func image(for kind: ProviderKind) -> NSImage? {
            let key = kind.rawValue
            lock.lock()
            defer { lock.unlock() }
            if let image = images[key] { return image }
            if missingAssets.contains(key) { return nil }

            guard let image = Self.loadImage(for: kind) else {
                missingAssets.insert(key)
                return nil
            }
            images[key] = image
            return image
        }

        private static func loadImage(for kind: ProviderKind) -> NSImage? {
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
                // 暂无 bundled 品牌资源 → 回退到 SF Symbol（见 body 的 fallback 分支）
                return nil
            }
        }

        private static func loadSvg(_ name: String) -> NSImage? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }

        /// 没有 bundled 品牌资源的 provider 回退用的 SF Symbol。
        static func fallbackSymbol(for kind: ProviderKind) -> String? {
            switch kind {
            case .glmCodingPlan: return "chevron.left.forwardslash.chevron.right"
            case .deepseek:      return "creditcard.fill"
            default: return nil
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
            if let image = Self.imageCache.image(for: kind) {
                if kind == .codexChatGpt {
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
            } else if let symbol = Self.ImageCache.fallbackSymbol(for: kind) {
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

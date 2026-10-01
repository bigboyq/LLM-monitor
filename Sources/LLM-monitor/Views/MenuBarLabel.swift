import SwiftUI
import AppKit

/// 菜单栏图标视图 — 固宽精致图标，动态感知 Provider 健康度与刷新状态
///
/// 重绘协议：`MenuBarExtra` 对 label 内的 `@Published` 观察不可靠（实测 body 不会
/// 重 eval），但 `@State` 变化一定能强制重绘——这是 `statusRevision` bump 生效的
/// 原理。之前的实现每次 `statusDidChange` 都无条件 bump + 重合成 NSImage；现在
/// 只有"可见输入签名"（图标样式 / 健康度 / 圆点开关 / 刷新中 / 外观）真正变化时
/// 才重合成 + bump，其余状态变化零开销。
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore
    @Environment(\.colorScheme) private var colorScheme
    /// 改变 `.id()` 强制 MenuBarExtra 丢弃缓存的 label 内容。
    @State private var statusRevision: UInt = 0
    /// 上次合成图像时的可见输入签名。
    @State private var renderedSignature: RenderSignature?
    /// 缓存的合成图像。`.id(statusRevision)` 只作用在内容子视图上，这两个
    /// @State 存在于本 view，不会随子视图 identity 变化被重置。
    @State private var cachedImage: NSImage?

    /// 决定菜单栏图像内容的全部输入。任一变化才需要重合成 NSImage。
    struct RenderSignature: Equatable {
        let iconStyle: StatusBarIconStyle
        let health: HealthLevel?
        let quotaMetrics: StatusBarQuotaMetrics?
        let energyHealth: HealthLevel?
        let showsHealthDot: Bool
        let healthColors: StatusBarHealthColors
        let isRefreshing: Bool
        let colorScheme: ColorScheme
    }

    var body: some View {
        // 分钟脉冲由 AppState 发布。不要在 MenuBarExtra label 内放 TimelineView：
        // 部分 macOS 版本会因此持续重建 status item 图像，导致 CPU/内存失控。
        let iconStyle = configStore.config.effectiveStatusBarIconStyle
        let showsHealthDot = configStore.config.effectiveStatusBarHealthDotEnabled
        let healthColors = configStore.config.effectiveStatusBarHealthColors
        let health = state.systemHealthLevel(at: state.healthEvaluationDate)
        // 只对真的消费它的样式算指标：`statusBarQuotaMetrics` 要把全部 provider 的
        // 额度窗口聚合一遍，代价远高于这里其余几项。与 `rerenderIfNeeded` 的签名
        // 用同一个判据——只改签名不跳过计算的话，收益基本为零（每次额度广播照样
        // 每个 provider 聚合一次，只是最后不再重合成图像）。
        let quotaMetrics = iconStyle.consumesQuotaMetrics
            ? state.statusBarQuotaMetrics(at: state.healthEvaluationDate)
            : nil
        let energyHealth = currentEnergyHealth

        content(
            iconStyle: iconStyle,
            health: health,
            quotaMetrics: quotaMetrics,
            energyHealth: energyHealth,
            showsHealthDot: showsHealthDot,
            healthColors: healthColors
        )
            .frame(width: 22, height: 22)
            .accessibilityLabel(accessibilityTitle(health: health))
            .onAppear {
                rerenderIfNeeded()
            }
            .onReceive(state.statusDidChange) { _ in
                // SleepHealthService 的 @Published/objectWillChange 会在属性写入前发出。
                // 延到下一轮主队列，确保闪电读取到新 report / keep-awake 值；普通
                // provider 状态变化同样安全地合并为一次最终渲染。
                DispatchQueue.main.async {
                    rerenderIfNeeded()
                }
            }
            .onReceive(configStore.$config.dropFirst()) { _ in
                rerenderIfNeeded()
            }
            .onReceive(state.$healthEvaluationDate.dropFirst()) { _ in
                rerenderIfNeeded()
            }
    }

    @ViewBuilder
    private func content(
        iconStyle: StatusBarIconStyle,
        health: HealthLevel?,
        quotaMetrics: StatusBarQuotaMetrics?,
        energyHealth: HealthLevel?,
        showsHealthDot: Bool,
        healthColors: StatusBarHealthColors
    ) -> some View {
        if state.isRefreshing {
            Image(systemName: "arrow.triangle.2.circlepath")
                .id(statusRevision)
        } else if let cachedImage {
            // MenuBarExtra 对 label 内的 SwiftUI overlay/ZStack 支持不稳定，
            // 先合成为单张原色图，再交给系统状态栏绘制。
            Image(nsImage: cachedImage)
                .renderingMode(.original)
                .accessibilityHidden(true)
                .id(statusRevision)
        } else {
            // onAppear 前的首帧；随后 rerenderIfNeeded 会缓存并接管。
            Image(nsImage: Self.composedMenuBarImage(
                iconStyle: iconStyle,
                health: health,
                quotaMetrics: quotaMetrics ?? .full,
                energyHealth: energyHealth,
                showsHealthDot: showsHealthDot,
                healthColors: healthColors
            ))
                .renderingMode(.original)
                .accessibilityHidden(true)
        }
    }

    private func rerenderIfNeeded() {
        let iconStyle = configStore.config.effectiveStatusBarIconStyle
        let signature = RenderSignature(
            iconStyle: iconStyle,
            health: state.systemHealthLevel(at: state.healthEvaluationDate),
            // **只对真的消费它的样式取指标**：`.quotaLogo` 已经是固定设计稿、另外四种
            // 是系统符号，都不读额度；无条件带上它会让每次额度广播（每个 provider 一次）
            // 都改变签名，把完全不相关的五种样式也逼着重合成一次 NSImage。
            quotaMetrics: iconStyle.consumesQuotaMetrics
                ? state.statusBarQuotaMetrics(at: state.healthEvaluationDate)
                : nil,
            energyHealth: currentEnergyHealth,
            showsHealthDot: configStore.config.effectiveStatusBarHealthDotEnabled,
            healthColors: configStore.config.effectiveStatusBarHealthColors,
            isRefreshing: state.isRefreshing,
            colorScheme: colorScheme
        )
        guard cachedImage == nil || renderedSignature != signature else { return }
        renderedSignature = signature
        cachedImage = Self.composedMenuBarImage(
            iconStyle: signature.iconStyle,
            health: signature.health,
            quotaMetrics: signature.quotaMetrics ?? .full,
            energyHealth: signature.energyHealth,
            showsHealthDot: signature.showsHealthDot,
            healthColors: signature.healthColors
        )
        statusRevision &+= 1
    }

    static func composedMenuBarImage(
        iconStyle: StatusBarIconStyle,
        health: HealthLevel?,
        quotaMetrics: StatusBarQuotaMetrics = .full,
        energyHealth: HealthLevel? = nil,
        showsHealthDot: Bool = true,
        healthColors: StatusBarHealthColors = .default
    ) -> NSImage {
        let canvasSize = NSSize(width: 22, height: 22)
        let baseRect = Self.baseDrawRect(for: iconStyle, canvas: canvasSize.width)
        let baseImage: NSImage?
        switch iconStyle {
        case .quotaLogo:
            // 「App 图标」**不再动态绘制**：直接用 picker 里那张设计稿（同一份
            // 资源，`.quotaLogo` 的预览图本来就是它，且都已裁掉留白）。原先这里用
            // 指标现画双环 + 水位杯，菜单栏里那个小尺寸的动态版本和设计稿对不上——
            // 同一个选项在设置页和菜单栏长得不一样，而"选的就是这个图标"应该字面成立。
            baseImage = Self.appIconDesignImage
        case .iconDuo:
            // 「Icon Duo」仪表盘：左右额度弧、中心扇形、底部套餐点与顶部节能点。
            baseImage = IconDuoSVGBuilder.buildImage(
                metrics: quotaMetrics,
                healthColors: healthColors,
                energyHealth: energyHealth
            )
        default:
            let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            baseImage = NSImage(
                systemSymbolName: iconStyle.systemImageName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(baseConfiguration)
        }

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            // 画哪一块由 `baseDrawRect` 决定：系统符号与 Icon Duo 走 1pt 边距的
            // 20pt 框，「App 图标」按 18pt 居中（它的留白在载入时已裁掉）。
            baseImage?.draw(in: baseRect)

            // 自带完整图形的两种样式（App 图标设计稿、Icon Duo 仪表盘）不再叠加
            // 通用状态圆点：设计稿没有给圆点留位置，Icon Duo 的边缘弧贴着画布。
            let shouldShowHealthDot = showsHealthDot && !iconStyle.isDashboardStyle
            if shouldShowHealthDot, let dotColor = statusDotColor(for: health, colors: healthColors) {
                dotColor.setFill()
                // AppKit 坐标原点在左下角，因此 x=16、y=0 对齐右下角。
                NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 6, height: 6)).fill()
            }
            return true
        }
        // 保留状态圆点颜色；主图标只使用动态 labelColor。
        image.isTemplate = false
        return image
    }

    /// 顶部闪电复用「节能」模块的三色语义：正常休眠为绿，睡眠受阻为黄，
    /// 本 App 开启防休眠为红；首轮探测完成前为灰色。
    private var currentEnergyHealth: HealthLevel? {
        if state.sleepHealth.isKeepAwakeOn {
            return .critical
        }
        return state.sleepHealth.report?.status.healthLevel
    }

    static func statusDotColor(
        for health: HealthLevel?,
        colors: StatusBarHealthColors = .default
    ) -> NSColor? {
        colors.color(for: health)
    }

    /// App 图标设计稿（llm-quota-730-2-dark.svg）：设置页 picker 预览与菜单栏图标使用。
    /// SwiftPM 会把 .copy 资源打平到 bundle Resources 根目录，与 BrandLogo 同款查找方式。
    ///
    /// **载入时就裁掉透明留白**，而不是让每个调用方各自裁：设计稿的画布是 1024 见方，
    /// 图形只占中间约 59%，四边各有几十点透明边距。谁按画布尺寸用它，谁的东西就跟着
    /// 一起缩小 41%——菜单栏里那个图标只有 11.7pt（比旁边的系统符号小一圈），设置页
    /// 那个固定 18pt 的预览框里更是只剩 10.5pt。在资源这一层裁一次，两个消费方
    /// （菜单栏、picker 预览）拿到的就都是"图形本身"，谁缩放都不会再失真。
    ///
    /// 裁剪在 256px 栅格上做（≈6.5 万像素，一次性不到 1ms），精度约画布的 0.4%
    /// （落到菜单栏 22pt 上是 0.09pt），细过任何显示设备能分辨的差别；结果按栅格
    /// 比例裁剪位图而不是重画矢量，缩放质量不受影响。留不出不透明像素（全透明资源）
    /// 或加载失败时原样返回，绝不返回一张空白图——那会让图标整个消失。
    static let appIconDesignImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "llm-quota-730-2-dark", withExtension: "svg"),
              let source = NSImage(contentsOf: url)
        else { return nil }

        let edge = 256
        guard let context = CGContext(
            data: nil, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()

        // `makeImage()` 必须**画完之后**才取：它快照的是上下文的当前内容，先取再画
        // 得到的是一张全透明图，扫描会得出"没有不透明像素"→ 退回整幅画布，裁剪静默
        // 失效（图标还是那么小，但没有任何报错）。
        guard let rendered = context.makeImage(),
              let data = rendered.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return source }

        let bytesPerRow = rendered.bytesPerRow
        var minX = edge, maxX = -1, minY = edge, maxY = -1
        for y in 0..<edge {
            for x in 0..<edge where bytes[y * bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = rendered.cropping(to: CGRect(
                  x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
              ))
        else { return source }

        let side = NSSize(width: 22, height: 22)
        // 保留宽高比：设计稿今天是正方形，但"按栅格比例裁"不该顺手把非正方形的设计
        // 拉成正方形。
        let aspect = CGFloat(cropped.height) / CGFloat(cropped.width)
        let image = NSImage(cgImage: cropped, size: aspect >= 1
                            ? NSSize(width: side.width / aspect, height: side.height)
                            : NSSize(width: side.width, height: side.width * aspect))
        return image
    }()

    /// 「App 图标」在画布上的边长。
    ///
    /// 22pt（铺满画布）看着偏大，20pt（与系统符号同一个绘制框）又偏小，18pt 落在
    /// Icon Duo 仪表盘（17.1pt）与旧的双环动态绘制（约 20pt）之间，是菜单栏里一排
    /// 图标里不抢戏也不显小的那一档。定成一个常量而不是散在调用处：改一次就够，
    /// 而且能与 `baseDrawRect` 的断言对齐。
    static let appIconDesignDrawSide: CGFloat = 18

    /// 菜单栏图标在画布上的**绘制矩形**（居中）。
    ///
    /// 「App 图标」按 `appIconDesignDrawSide` 居中放——它的留白已在资源加载时裁掉，
    /// 这里的边长就是图形真实边长，不用再留出透明边距。系统符号与 Icon Duo 沿用
    /// 1pt 边距的 20pt 框：SF Symbol 自带内边距（画出来的字形只占框的 70~78%），
    /// Icon Duo 的 SVG 也是紧凑画布，两者都靠这个框把视觉尺寸压到 15~17pt。
    static func baseDrawRect(for iconStyle: StatusBarIconStyle, canvas: CGFloat) -> CGRect {
        let side: CGFloat
        switch iconStyle {
        case .quotaLogo: side = min(appIconDesignDrawSide, canvas)
        case .iconDuo, .chartBar, .sparkles, .brain, .cpu: side = canvas - 2
        }
        return CGRect(
            x: (canvas - side) / 2, y: (canvas - side) / 2,
            width: side, height: side
        )
    }

    /// 完整 App 图标（icon-master.png，含圆角底与渐变背景）：主面板 header 使用。
    /// 与设计稿同样归一到 22pt 画布，由调用方按需缩放。源 PNG 为 1024px，但
    /// header 仅以 24pt 显示（Retina @3x 也只 72px），直接持有会让约 4MB 的
    /// 解码位图终生常驻；这里绘制进 128px 位图再持有（约 64KB），对该显示
    /// 尺寸视觉无损，且没有任何调用方把它放大使用。
    static let appIconMasterImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "icon-master", withExtension: "png") else {
            return nil
        }
        guard let source = NSImage(contentsOf: url) else { return nil }
        let edge = 128
        guard let context = CGContext(
            data: nil, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 22, height: 22))
    }()

    private func accessibilityTitle(health: HealthLevel?) -> String {
        var title = "LLM Monitor"
        if state.isRefreshing {
            title += " - 刷新中"
        } else if let health {
            switch health {
            case .healthy:
                title += " - 正常"
            case .warning:
                title += " - 额度预警/高峰期"
            case .critical:
                title += " - 服务异常"
            }
        }
        return title
    }
}

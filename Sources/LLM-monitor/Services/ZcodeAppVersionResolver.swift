import AppKit

/// 解析本机安装的 ZCode.app 版本号，供 ZCode 直连 API 的
/// `app_version` query 与 `X-ZCode-App-Version` header 使用。
///
/// 背景：ZCode 服务端按客户端版本做门槛校验，硬编码版本号会随客户端升级过期。
/// 这里通过 bundle identifier 定位本机安装的 ZCode.app（不写死 /Applications 路径），
/// 读取其 `Contents/Info.plist` 的 `CFBundleShortVersionString`；任一环节失败
/// （未安装、plist 不可读、值为空）都回退到 `defaultAppVersion`，绝不 throw。
///
/// 结果进程内缓存（解析一次即可），`refreshCachedAppVersion()` 为显式刷新入口；
/// `infoPlistURL` / `resolveAppVersion` 均可注入路径，便于单测。
enum ZcodeAppVersionResolver {
    static let zcodeBundleIdentifier = "dev.zcode.app"

    private static let lock = NSLock()
    private static var cachedVersion: String?

    /// 当前应使用的 ZCode app 版本号：优先返回缓存，未缓存时解析并缓存。
    static var currentAppVersion: String {
        lock.lock()
        if let cached = cachedVersion {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return refreshCachedAppVersion()
    }

    /// 强制重新解析并覆盖缓存。`infoPlistURL` 非空时直接使用该路径（测试注入），
    /// 否则按 bundle identifier 定位本机 ZCode.app。
    @discardableResult
    static func refreshCachedAppVersion(
        bundleIdentifier: String = zcodeBundleIdentifier,
        infoPlistURL: URL? = nil,
        fallback: String = GlmZcodeAPIClient.defaultAppVersion
    ) -> String {
        let plistURL = infoPlistURL ?? Self.infoPlistURL(forBundleIdentifier: bundleIdentifier)
        let version = resolveAppVersion(infoPlistURL: plistURL, fallback: fallback)
        lock.lock()
        cachedVersion = version
        lock.unlock()
        return version
    }

    /// 清空缓存，下次访问 `currentAppVersion` 时重新解析（测试辅助）。
    static func invalidateCache() {
        lock.lock()
        cachedVersion = nil
        lock.unlock()
    }

    /// 定位本机安装应用的 `Contents/Info.plist`；未安装返回 nil。
    static func infoPlistURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?
            .appendingPathComponent("Contents/Info.plist")
    }

    /// 从指定 Info.plist 解析 `CFBundleShortVersionString`；plist 不可读、
    /// 结构非字典或值为空字符串时回退 fallback，任何异常都不外抛。
    static func resolveAppVersion(infoPlistURL: URL?, fallback: String) -> String {
        guard let infoPlistURL else { return fallback }
        guard let data = try? Data(contentsOf: infoPlistURL) else { return fallback }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return fallback
        }
        let raw = (dict["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? fallback : raw
    }
}

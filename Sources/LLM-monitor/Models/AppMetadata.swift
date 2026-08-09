import Foundation

enum AppMetadata {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "开发版"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "本地"
}

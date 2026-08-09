import Foundation

/// 通用字符串小工具 — 纯函数，方便测试。
enum StringUtilities {
    /// trim 后非空字符串，否则 nil
    static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// 取第一个 trim 后非空的字符串，全 nil/空则返回 nil
    static func firstTrimmed(_ values: String?...) -> String? {
        for v in values {
            if let t = trimmedOrNil(v) { return t }
        }
        return nil
    }
}

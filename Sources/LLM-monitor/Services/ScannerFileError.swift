import Foundation

/// 文件扫描器共用的“明确不存在”判断。
///
/// 权限、TCC、瞬时 I/O 和资源繁忙错误不能等价为删除，否则 scanner 会误删
/// last-good cache。Foundation 有时直接抛 Cocoa 错误，有时把 POSIX ENOENT
/// 包在 underlying error 中，所以这里统一递归检查两类错误。
enum ScannerFileError {
    nonisolated static func isExplicitlyMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            if nsError.code == NSFileNoSuchFileError
                || nsError.code == NSFileReadNoSuchFileError
                || nsError.code == CocoaError.Code.fileNoSuchFile.rawValue {
                return true
            }
        case NSPOSIXErrorDomain:
            if nsError.code == Int(ENOENT) {
                return true
            }
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isExplicitlyMissing(underlying)
        }
        return false
    }
}

import Foundation

/// Stores the local device identity outside the synchronizable application config.
/// The file is intentionally independent of config.json so copying the config does
/// not copy a machine's identity to another device.
struct DeviceIdentityStore {
    let configDirectory: URL

    private let fileManagerBox: FileManagerBox

    init(configDirectory: URL) {
        self.configDirectory = configDirectory
        self.fileManagerBox = FileManagerBox()
    }

    var fileURL: URL {
        configDirectory.appendingPathComponent(".deviceId", isDirectory: false)
    }

    /// Returns the existing UUID or creates and persists a new one.
    /// An existing unreadable or malformed file is an error; silently replacing it
    /// could split one device's history across identities.
    func loadOrCreate() throws -> UUID {
        try fileManagerBox.createPrivateDirectory(at: configDirectory)

        do {
            let data = try fileManagerBox.contents(at: fileURL)
            guard let text = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DeviceIdentityStoreError.invalidFile
            }
            return uuid
        } catch {
            guard ScannerFileError.isExplicitlyMissing(error) else { throw error }
        }

        let uuid = UUID()
        let contents = Data((uuid.uuidString + "\n").utf8)
        try fileManagerBox.writePrivate(contents, to: fileURL)
        return uuid
    }
}

enum DeviceIdentityStoreError: LocalizedError {
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "设备身份文件格式无效；请检查配置目录中的 .deviceId"
        }
    }
}

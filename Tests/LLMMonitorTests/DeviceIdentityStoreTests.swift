import Darwin
import Foundation
import XCTest
@testable import LLM_monitor

final class DeviceIdentityStoreTests: XCTestCase {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setImmutable(_ url: URL, _ immutable: Bool) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.chflags(path, immutable ? UInt32(UF_IMMUTABLE) : 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func setPermissions(_ url: URL, _ mode: mode_t) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.chmod(path, mode)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func testLoadOrCreatePersistsAndReusesIdentityAfterRestart() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DeviceIdentityStore(configDirectory: directory)
        XCTAssertEqual(store.fileURL.lastPathComponent, ".deviceId")

        let first = try store.loadOrCreate()
        let contents = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "\(first.uuidString)\n")

        let restartedStore = DeviceIdentityStore(configDirectory: directory)
        XCTAssertEqual(try restartedStore.loadOrCreate(), first)
    }

    func testCopiedConfigWithSameLegacyNodeIDGetsIndependentIdentities() throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let legacyID = UUID()
        let copiedConfig = "{\"sync\":{\"enabled\":true,\"nodeID\":\"\(legacyID.uuidString)\"}}"
        for directory in [firstDirectory, secondDirectory] {
            try Data(copiedConfig.utf8).write(to: directory.appendingPathComponent("config.json"))
        }

        let first = try DeviceIdentityStore(configDirectory: firstDirectory).loadOrCreate()
        let second = try DeviceIdentityStore(configDirectory: secondDirectory).loadOrCreate()
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, legacyID)
        XCTAssertNotEqual(second, legacyID)
    }

    func testReadsExistingUUIDAfterTrimmingTrailingNewline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = UUID()
        let store = DeviceIdentityStore(configDirectory: directory)
        for suffix in ["\n", "\r\n"] {
            let contents = "\(expected.uuidString)\(suffix)"
            try Data(contents.utf8).write(to: store.fileURL)

            XCTAssertEqual(try store.loadOrCreate(), expected)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), Data(contents.utf8))
        }
    }

    func testExistingMalformedIdentityIsNotReplaced() throws {
        let malformedContents = ["", "not-a-uuid\n", "\(UUID().uuidString)\nextra\n"]

        for malformed in malformedContents {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = DeviceIdentityStore(configDirectory: directory)
            let bytes = Data(malformed.utf8)
            try bytes.write(to: store.fileURL)

            XCTAssertThrowsError(try store.loadOrCreate(), "malformed identity must fail closed")
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "malformed bytes must not be overwritten")
        }
    }

    func testUnreadableExistingIdentityIsNotReplacedAsMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = UUID()
        let store = DeviceIdentityStore(configDirectory: directory)
        let originalContents = Data("\(expected.uuidString)\n".utf8)
        try originalContents.write(to: store.fileURL)
        try setPermissions(store.fileURL, 0)
        defer { try? setPermissions(store.fileURL, 0o600) }

        let isReadable = store.fileURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return Darwin.access(path, R_OK) == 0
        }
        if isReadable {
            throw XCTSkip("filesystem permissions allow this process to read chmod 000 files")
        }

        XCTAssertThrowsError(try store.loadOrCreate(), "an unreadable existing identity must fail closed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber,
                       NSNumber(value: 0))
    }

    func testIdentityFileUsesPrivatePermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DeviceIdentityStore(configDirectory: directory)
        _ = try store.loadOrCreate()
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value

        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
    }

    func testIdentityCreationDoesNotDependOnConfigFileWritePermission() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        try Data("{\"sync\":{\"nodeID\":\"legacy\"}}".utf8).write(to: configURL)

        try setImmutable(configURL, true)
        defer { try? setImmutable(configURL, false) }

        let identity = try DeviceIdentityStore(configDirectory: directory).loadOrCreate()
        XCTAssertEqual(try DeviceIdentityStore(configDirectory: directory).loadOrCreate(), identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testWriteFailureDoesNotReturnUnpersistedIdentityAndCanRetryStably() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A regular file where the config directory should be blocks creation of .deviceId.
        let blockedDirectory = root.appendingPathComponent("blocked-config-directory")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let blockedStore = DeviceIdentityStore(configDirectory: blockedDirectory)
        XCTAssertThrowsError(try blockedStore.loadOrCreate(), "directory creation failure must not return a staged UUID")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedStore.fileURL.path))

        try FileManager.default.removeItem(at: blockedDirectory)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: false)
        let recoveredStore = DeviceIdentityStore(configDirectory: blockedDirectory)
        let persisted = try recoveredStore.loadOrCreate()
        XCTAssertEqual(try recoveredStore.loadOrCreate(), persisted)
    }

    func testImmutableIdentityDirectoryFailureDoesNotReturnStagedIdentityAndCanRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DeviceIdentityStore(configDirectory: directory)
        try setImmutable(directory, true)
        defer { try? setImmutable(directory, false) }

        XCTAssertThrowsError(
            try store.loadOrCreate(),
            "identity creation must fail when the identity directory cannot be written"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        try setImmutable(directory, false)
        let persisted = try store.loadOrCreate()
        XCTAssertEqual(try store.loadOrCreate(), persisted)
    }

    func testExistingDirectoryAtIdentityPathFailsWithoutReturningStagedIdentity() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DeviceIdentityStore(configDirectory: directory)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.loadOrCreate(), "an un-readable identity path must not trigger a fallback UUID")

        try FileManager.default.removeItem(at: store.fileURL)
        let persisted = try store.loadOrCreate()
        XCTAssertEqual(try store.loadOrCreate(), persisted)
    }
}

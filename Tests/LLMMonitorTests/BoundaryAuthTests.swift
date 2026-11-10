import Foundation
import XCTest
@testable import LLM_monitor

final class BoundaryAuthTests: XCTestCase {
    private func makeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boundary-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("controlled-agy")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func makeBlockedScript() throws -> (script: URL, started: URL, release: URL, completed: URL) {
        let script = try makeScript("")
        let directory = script.deletingLastPathComponent()
        let started = directory.appendingPathComponent("started")
        let release = directory.appendingPathComponent("release")
        let completed = directory.appendingPathComponent("completed")
        try """
        #!/bin/sh
        /usr/bin/touch '\(started.path)'
        while [ ! -f '\(release.path)' ]; do /bin/sleep 0.01; done
        /usr/bin/touch '\(completed.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, started, release, completed)
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "controlled process did not start")
    }

    func testParentCancellationTerminatesActualDetachedAgyAndSkipsCredentialReread() async throws {
        let fixture = try makeBlockedScript()
        let reader = AntigravityCountingCredentialReader(credential: nil)
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            agyLocator: { fixture.script.path },
            agyRunner: { try await AntigravityAgyCLI.runModels(executablePath: $0) }
        )
        let fetcher = AntigravityFetcher(
            localServerDiscovery: { throw QuotaError.networkError("controlled missing server") },
            policy: policy
        )
        let refresh = Task { try await fetcher.fetch(mode: .background) }
        try await waitForFile(fixture.started)
        refresh.cancel()
        // An old, uncancelled detached worker is allowed to exit, so a regression
        // fails with its post-cancel side effects rather than hanging for 30s.
        let release = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try Data().write(to: fixture.release)
        }
        do {
            _ = try await refresh.value
            XCTFail("cancelled refresh returned success")
        } catch is CancellationError {
        } catch {
            XCTFail("cancelled refresh returned \(error)")
        }
        release.cancel()
        _ = await release.result
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.completed.path))
        XCTAssertEqual(reader.readCount, 1, "cancelled agy must not force another keychain read")
        XCTAssertFalse(policy.isBackedOff(), "cancelled refresh must not poison the next refresh")
    }

    func testAlreadyCancelledCallerDoesNotLaunchAgy() async throws {
        let fixture = try makeBlockedScript()
        try Data().write(to: fixture.release)
        let gate = TestAsyncGate()
        let refresh = Task {
            await gate.hold()
            return try await AntigravityAgyCLI.runModels(executablePath: fixture.script.path)
        }
        await gate.waitUntilReached()
        refresh.cancel()
        await gate.release()
        do {
            _ = try await refresh.value
            XCTFail("already cancelled caller launched agy")
        } catch is CancellationError {
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.started.path))
    }

    func testCancellationAfterNoncooperativeAgyOutcomesDoesNotReadOrBackOff() async throws {
        let outcomes: [AntigravityAgyRunOutcome?] = [.success, .failure(reloginRequired: false), nil]
        for outcome in outcomes {
            let gate = TestAsyncGate()
            let reader = AntigravityCountingCredentialReader(credential: nil)
            let policy = AntigravityCredentialPolicy(
                credentialReader: { reader.read() },
                agyLocator: { "/controlled/agy" },
                agyRunner: { _ in
                    await gate.hold()
                    guard let outcome else { throw QuotaError.networkError("controlled runner failure") }
                    return outcome
                }
            )
            let fetcher = AntigravityFetcher(
                localServerDiscovery: { throw QuotaError.networkError("controlled missing server") },
                policy: policy
            )
            let refresh = Task { try await fetcher.fetch(mode: .background) }
            await gate.waitUntilReached()
            refresh.cancel()
            await gate.release()
            do {
                _ = try await refresh.value
                XCTFail("cancelled runner result was accepted")
            } catch is CancellationError {
            } catch { XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(reader.readCount, 1)
            XCTAssertFalse(policy.isBackedOff())
        }
    }

    func testCancelledLocalFailureDoesNotEnterCredentialFallback() async throws {
        let gate = TestAsyncGate()
        let reader = AntigravityCountingCredentialReader(credential: nil)
        let policy = AntigravityCredentialPolicy(credentialReader: { reader.read() })
        let fetcher = AntigravityFetcher(
            localServerDiscovery: {
                await gate.hold()
                // pgrep/lsof discovery can map a subprocess cancellation into
                // an unavailable-server error; the fetch boundary must recheck.
                throw QuotaError.networkError("controlled discovery failure")
            },
            policy: policy
        )
        let refresh = Task { try await fetcher.fetch(mode: .background) }
        await gate.waitUntilReached()
        refresh.cancel()
        await gate.release()
        do {
            _ = try await refresh.value
            XCTFail("cancelled local failure entered fallback")
        } catch is CancellationError {
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertFalse(policy.isBackedOff())
    }

    func testUncancelledAgyStillClassifiesSuccessAndInvalidGrant() async throws {
        let success = try makeScript("exit 0\n")
        let invalid = try makeScript("/usr/bin/printf invalid_grant >&2\nexit 1\n")
        let ordinary = try makeScript("exit 2\n")
        let successResult = try await AntigravityAgyCLI.runModels(executablePath: success.path)
        let invalidResult = try await AntigravityAgyCLI.runModels(executablePath: invalid.path)
        let ordinaryResult = try await AntigravityAgyCLI.runModels(executablePath: ordinary.path)
        XCTAssertEqual(successResult, .success)
        XCTAssertEqual(invalidResult, .failure(reloginRequired: true))
        XCTAssertEqual(ordinaryResult, .failure(reloginRequired: false))
    }
}

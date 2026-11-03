import Foundation
import XCTest
@testable import LLM_monitor

final class AntigravityRefreshCadenceTests: XCTestCase {
    private let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private let loadCodeAssistPath = "/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist"
    private let quotaPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    func testBackgroundFetchCallsOnlyQuotaRPC() async throws {
        let stub = RPCStub()
        let fetcher = makeFetcher(stub: stub)

        _ = try await fetcher.fetch(mode: .background)

        let paths = await stub.paths()
        XCTAssertEqual(paths, [quotaPath])
    }

    func testFullFetchCallsQuotaAndBothMetadataRPCs() async throws {
        let stub = RPCStub()
        let fetcher = makeFetcher(stub: stub)

        let result = try await fetcher.fetch(mode: .full)

        let paths = await stub.paths()
        XCTAssertEqual(Set(paths), Set([userStatusPath, loadCodeAssistPath, quotaPath]))
        XCTAssertEqual(result.accountEmail, "user@example.com")
        XCTAssertEqual(result.planLabel, "Pro")
    }

    func testMetadataFailuresDoNotFailQuotaFetch() async throws {
        let stub = RPCStub(failedPaths: [userStatusPath, loadCodeAssistPath])
        let fetcher = makeFetcher(stub: stub)

        let result = try await fetcher.fetch(mode: .full)

        let paths = await stub.paths()
        XCTAssertEqual(Set(paths), Set([userStatusPath, loadCodeAssistPath, quotaPath]))
        XCTAssertNil(result.accountEmail)
        XCTAssertNil(result.planLabel)
        XCTAssertFalse(result.models.isEmpty)
    }

    func testQuotaFailureStillThrows() async {
        let stub = RPCStub(failedPaths: [quotaPath])
        let fetcher = makeFetcher(stub: stub)

        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("主额度接口失败必须抛错")
        } catch {
            let paths = await stub.paths()
            XCTAssertEqual(Set(paths), Set([quotaPath]))
        }
    }

    private func makeFetcher(stub: RPCStub) -> AntigravityFetcher {
        let server = AntigravityFetcher.ServerInfo(pid: 1, httpsPort: 1, csrfToken: nil, kind: .ide)
        return AntigravityFetcher(
            quotaServerDiscovery: { server },
            rawRPCOverride: { _, path, _ in
                let (data, statusCode) = await stub.response(for: path)
                let response = HTTPURLResponse(
                    url: URL(string: "https://127.0.0.1/rpc")!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )
    }

    private actor RPCStub {
        private let failedPaths: Set<String>
        private var requestedPaths: [String] = []

        init(failedPaths: Set<String> = []) {
            self.failedPaths = failedPaths
        }

        func paths() -> [String] { requestedPaths }

        func response(for path: String) -> (Data, Int) {
            requestedPaths.append(path)
            if failedPaths.contains(path) {
                return (Data("{}".utf8), 503)
            }
            let json: String
            switch path {
            case "/exa.language_server_pb.LanguageServerService/GetUserStatus":
                json = #"{"userStatus":{"email":"user@example.com","userTier":{"name":"Pro"}}}"#
            case "/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist":
                json = #"{"response":{"currentTier":{"name":"Fallback"}}}"#
            case "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary":
                json = #"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.8}]}]}}"#
            default:
                json = "{}"
            }
            return (Data(json.utf8), 200)
        }
    }
}

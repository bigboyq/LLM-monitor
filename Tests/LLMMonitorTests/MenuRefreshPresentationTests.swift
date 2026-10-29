import XCTest
@testable import LLM_monitor

final class MenuRefreshPresentationTests: XCTestCase {
    private func status(at date: Date, enabled: Bool = true) -> ProviderStatus {
        ProviderStatus(
            id: "codex_chatgpt", displayName: "ChatGPT Plan", kind: .codexChatGpt,
            iconSystemName: "sparkles", accentColor: .chatgpt,
            refreshIntervalSeconds: 300, isEnabled: enabled,
            state: .ok(QuotaInfo(
                models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: date
            )), lastRefreshedAt: date
        )
    }

    @MainActor
    func testQuotaTimestampUsesLatestEnabledSuccessfulData() {
        let old = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(MenuContentView.providerQuotaUpdatedAt(statuses: [
            status(at: old), status(at: latest),
            status(at: Date(timeIntervalSince1970: 300), enabled: false)
        ]), latest)
    }

    @MainActor
    func testFailedRequestKeepsTheLastSuccessfulQuotaTimestamp() {
        let successful = Date(timeIntervalSince1970: 100)
        var failed = status(at: successful)
        failed.state = .failed(message: "offline", lastSuccess: failed.lastSuccess)
        failed.lastRefreshedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(MenuContentView.providerQuotaUpdatedAt(statuses: [failed]), successful)
    }

    @MainActor
    func testPersistedSuccessfulTimeSurvivesReadyStateAndEmptyHasNoTime() {
        let successful = Date(timeIntervalSince1970: 100)
        var ready = status(at: successful)
        ready.state = .ready
        XCTAssertEqual(MenuContentView.providerQuotaUpdatedAt(statuses: [ready]), successful)
        XCTAssertNil(MenuContentView.providerQuotaUpdatedAt(statuses: []))
    }
}

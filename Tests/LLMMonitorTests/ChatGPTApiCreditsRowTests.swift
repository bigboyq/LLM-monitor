import XCTest
@testable import LLM_monitor

@MainActor
final class ChatGPTApiCreditsRowTests: XCTestCase {
    func testNamedKeysUseTheirNamesInsteadOfCurrencyOrOrganization() {
        let now = Date()
        for name in ["个人账号", "团队项目"] {
            let credits = OpenAIApiCreditDetails(
                organizationName: "Shared Organization",
                totalQuota: 40,
                usedAmount: 5,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                keyLabel: " \(name) \n"
            )
            let row = ChatGPTApiCreditsRow(credits: credits, tint: .chatgptBrand, error: nil)
            XCTAssertEqual(row.titleText, "API赠金 · \(name)")
        }
    }

    func testUnnamedKeysRemainDistinguishableByListPosition() {
        let now = Date()
        for (index, label) in [nil, "", " \n"].enumerated() {
            let credits = OpenAIApiCreditDetails(
                organizationName: nil,
                totalQuota: 40,
                usedAmount: 0,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                keyLabel: label
            )
            let row = ChatGPTApiCreditsRow(
                credits: credits, tint: .chatgptBrand, error: nil, keyNumber: index + 1
            )
            XCTAssertEqual(row.titleText, "API赠金 · API Key #\(index + 1)")
        }
    }
}

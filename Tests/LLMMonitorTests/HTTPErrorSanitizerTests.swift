import XCTest
import Foundation
@testable import LLM_monitor

/// `HTTPRequestLogSanitizer`：URL 脱敏（query / userinfo / fragment / 非法 URL）
/// 与网络错误文案不得回显凭据 URL。
/// 拆自 `HTTPAndSQLiteTests`，逐字搬移零逻辑变化。
final class HTTPErrorSanitizerTests: XCTestCase {

    func testHTTPRequestLogSanitizerRemovesQueryCredentialsAndFragment() {
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://api.example.com/v1/usage?access_token=secret")
            ),
            "https://api.example.com/v1/usage"
        )
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://alice:password@example.com:8443/private")
            ),
            "https://example.com:8443/private"
        )
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://example.com/docs/start#bearer-secret")
            ),
            "https://example.com/docs/start"
        )
    }

    func testHTTPRequestLogSanitizerPreservesOrdinaryOriginAndPath() {
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://example.com:9443/v1/models")
            ),
            "https://example.com:9443/v1/models"
        )
    }

    func testHTTPRequestLogSanitizerUsesFixedInvalidPlaceholder() {
        XCTAssertEqual(HTTPRequestLogSanitizer.sanitizedURL(nil), "<invalid-url>")
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(URL(string: "relative/path")),
            "<invalid-url>"
        )
    }

    func testHTTPNetworkErrorDescriptionCannotEchoCredentialURL() {
        let secretURL = URL(string: "https://user:password@example.com/path?token=secret")!
        let error = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: secretURL]
        )

        let description = HTTPRequestLogSanitizer.networkErrorDescription(error)

        XCTAssertEqual(description, "无法连接服务器")
        XCTAssertFalse(description.contains("password"))
        XCTAssertFalse(description.contains("secret"))
    }
}

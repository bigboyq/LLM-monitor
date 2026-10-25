import Foundation

// MARK: - 副节点 HTTP 客户端（§4.1 / §4.2）

/// `GET /v1/health` 的响应形状（探活 + hubUUID 学习）。
struct FleetHealth: Codable, Equatable, Sendable {
    let ok: Bool
    let nodeID: UUID
    let protocolVersion: Int
}

enum SyncClientError: Error, CustomStringConvertible, Equatable {
    case invalidHubURL(String)

    var description: String {
        switch self {
        case .invalidHubURL(let raw):
            return "主节点地址非法：\(raw)"
        }
    }
}

/// 副节点侧的 HTTP 客户端：复用仓库既有 `HTTPClient`（超时、状态码校验、
/// 脱敏日志、响应体硬上限全部现成）。路径是固定常量，副节点只填
/// `http://<主节点IP>:8787`。
final class SyncClient: @unchecked Sendable {
    let upstreamKey: String
    private let http: HTTPClient
    private let baseURL: URL

    init(hubURL rawURL: String, session: URLSession = .shared) throws {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host()?.isEmpty == false
        else {
            throw SyncClientError.invalidHubURL(rawURL)
        }
        self.baseURL = url
        var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false)
        normalized?.path = ""
        normalized?.query = nil
        normalized?.fragment = nil
        self.upstreamKey = normalized?.string ?? trimmed
        self.http = HTTPClient(
            session: session,
            logTag: "[fleet-node]",
            defaultTimeout: 15,
            maxResponseBytes: FleetProtocol.maxResponseBodyBytes
        )
    }

    /// 推 + 取一次往返：POST 报告，返回 hub 合并后的全局快照（R3）。
    ///
    /// `includeBodyInError: true`：hub 用 409 回「本机序号落后」并在响应体里
    /// 带 high-water，node 据此重建本机序号（否则这份报告会永久被拒）。
    /// 响应体是本协议自己的错误 JSON，不含敏感数据。
    func postReport(_ report: NodeUsageReport) async throws -> FleetSnapshot {
        let body = try FleetCodec.encode(report)
        var request = URLRequest(url: baseURL.appendingPathComponent(FleetProtocol.usageDayPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        let (data, _) = try await http.send(request, includeBodyInError: true)
        return try FleetCodec.decode(FleetSnapshot.self, from: data)
    }

    /// push 失败时的兜底拉取（§4.2）。
    func fetchSnapshot() async throws -> FleetSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent(FleetProtocol.usageDayPath))
        request.httpMethod = "GET"
        let (data, _) = try await http.send(request)
        return try FleetCodec.decode(FleetSnapshot.self, from: data)
    }

    /// 探活 + 学习 hubUUID（§6.5：快照只接受已验证 hub 的）。
    func fetchHealth() async throws -> FleetHealth {
        var request = URLRequest(url: baseURL.appendingPathComponent(FleetProtocol.healthPath))
        request.httpMethod = "GET"
        let (data, _) = try await http.send(request)
        return try FleetCodec.decode(FleetHealth.self, from: data)
    }
}

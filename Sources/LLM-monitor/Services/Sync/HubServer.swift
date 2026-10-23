import Foundation
import Network

// MARK: - Hub HTTP 服务（§4.3）

/// hub 对单个请求的处理结果（业务层产出，`HubServer` 只负责 HTTP 外壳）。
struct HubServerResponse {
    let status: Int
    let reason: String
    let body: Data

    static func json(_ status: Int, _ reason: String, _ body: Data) -> HubServerResponse {
        HubServerResponse(status: status, reason: reason, body: body)
    }

    static func error(_ status: Int, _ reason: String, _ message: String) -> HubServerResponse {
        let payload = ["error": message]
        let body = (try? FleetCodec.encode(payload)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        return HubServerResponse(status: status, reason: reason, body: body)
    }
}

/// 业务处理器：`HubServer` 解析完 HTTP 后全部委托到这里。
/// 认证缝（§9.2）在 `HubServer` 进业务逻辑之前的那一行——将来加校验插在那里。
struct HubServerHandlers {
    /// POST /v1/usage/day 的 body。返回快照（200）或错误（400/429/500）。
    let processReport: @Sendable (Data) async -> HubServerResponse
    /// GET /v1/usage/day。
    let currentSnapshot: @Sendable () async -> HubServerResponse
    /// GET /v1/health。
    let health: @Sendable () async -> HubServerResponse
}

/// `Network.framework` 的 `NWListener` 上一个 HTTP/1.1 **最小子集**服务端：
/// - `Content-Length` 必填（不支持 chunked），超 4 MiB 立即 `413` 并断开；
/// - `Connection: close`（每请求一条连接，不做 keep-alive）；
/// - 路径白名单外 `404`；`Content-Type` 非 JSON `415`；
/// - 请求在独立 Task 处理，accept 循环不阻塞；
/// - 日志只记 `method path nodeID status bytes`（§4.3 / §9.3）。
///
/// hub 从不主动连副节点（§3 不变量 2）——本类型只监听。
final class HubServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LLM-monitor.fleet.hub-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HubConnection] = [:]
    private let connectionsLock = NSLock()
    private let handlers: HubServerHandlers
    private var connectionWatchdogs: [ObjectIdentifier: DispatchSourceTimer] = [:]

    /// 实际监听端口（端口传 0 时由系统分配；测试用）。
    private(set) var boundPort: UInt16?

    init(handlers: HubServerHandlers) {
        self.handlers = handlers
    }

    /// - Parameters:
    ///   - port: 监听端口；0 = 系统分配。
    ///   - loopbackOnly: 只绑 `127.0.0.1`（`hubBindHost` 为回环地址时）。
    func start(port: UInt16, loopbackOnly: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: .any
            )
        }
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.boundPort = listener.port?.rawValue
            }
            if case .failed(let error) = state {
                logError("[fleet-hub] NWListener 失败: \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        let watchdogs = Array(connectionWatchdogs.values)
        connectionWatchdogs.removeAll()
        connectionsLock.unlock()
        watchdogs.forEach { $0.cancel() }
        active.forEach { $0.connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let hubConnection = HubConnection(connection: connection, handlers: handlers)
        connectionsLock.lock()
        connections[ObjectIdentifier(hubConnection)] = hubConnection
        connectionsLock.unlock()
        trackWatchdog(for: hubConnection)
        connection.stateUpdateHandler = { [weak self, weak hubConnection] state in
            switch state {
            case .ready:
                hubConnection?.receiveLoop()
            case .failed, .cancelled:
                self?.forget(hubConnection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// 30s 连接看门狗：HTTP/1.1 + close 语义下，一条连接的总寿命不该超过它。
    private func trackWatchdog(for connection: HubConnection) {
        let id = ObjectIdentifier(connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self, weak connection] in
            guard let connection else { return }
            logWarn("[fleet-hub] 连接超时未完成，断开")
            connection.connection.cancel()
            self?.forget(connection)
        }
        timer.resume()
        connectionsLock.lock()
        connectionWatchdogs[id] = timer
        connectionsLock.unlock()
    }

    private func forget(_ connection: HubConnection?) {
        guard let connection else { return }
        let id = ObjectIdentifier(connection)
        connectionsLock.lock()
        connections.removeValue(forKey: id)
        connectionWatchdogs.removeValue(forKey: id)?.cancel()
        connectionsLock.unlock()
    }
}

// MARK: - 单连接状态机

/// 每条连接：收齐请求头 →（POST）按 Content-Length 收齐 body → 业务 Task → 回包 → 关闭。
final class HubConnection: @unchecked Sendable {
    let connection: NWConnection
    private let handlers: HubServerHandlers
    private var buffer = Data()
    private var requestHandled = false

    init(connection: NWConnection, handlers: HubServerHandlers) {
        self.connection = connection
        self.handlers = handlers
    }

    func receiveLoop() {
        receiveMore()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consume()
            }
            if error != nil {
                self.connection.cancel()
                return
            }
            if isComplete {
                return
            }
            if !self.requestHandled {
                self.receiveMore()
            }
        }
    }

    private struct RawRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func consume() {
        if requestHandled { return }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > FleetProtocol.maxHeaderBytes {
                respondAndClose(HubServerResponse.error(431, "Request Header Fields Too Large", "请求头超限"))
                requestHandled = true
            }
            return
        }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let request = parseHeaders(headerData) else {
            respondAndClose(HubServerResponse.error(400, "Bad Request", "请求行/头解析失败"))
            requestHandled = true
            return
        }
        let bodyStart = headerEnd.upperBound
        guard let contentLengthHeader = request.headers["content-length"] else {
            // GET / health 不带 body；POST 必须带 Content-Length（不支持 chunked）。
            if request.method == "POST" {
                respondAndClose(HubServerResponse.error(411, "Length Required", "POST 需要 Content-Length"))
                requestHandled = true
                return
            }
            dispatch(raw: RawRequest(method: request.method, path: request.path, headers: request.headers, body: Data()))
            requestHandled = true
            return
        }
        let contentLength = Int(contentLengthHeader) ?? -1
        guard contentLength >= 0 else {
            respondAndClose(HubServerResponse.error(400, "Bad Request", "Content-Length 非法"))
            requestHandled = true
            return
        }
        guard contentLength <= FleetProtocol.maxRequestBodyBytes else {
            // 超限立即 413，不等 body 读完（§4.3）。
            respondAndClose(HubServerResponse.error(413, "Payload Too Large", "请求体超过 4 MiB 上限"))
            requestHandled = true
            return
        }
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return } // 继续收
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        dispatch(raw: RawRequest(method: request.method, path: request.path, headers: request.headers, body: body))
        requestHandled = true
    }

    private func parseHeaders(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[..<queryStart])
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (method, path, headers)
    }

    private func dispatch(raw: RawRequest) {
        Task {
            let response: HubServerResponse
            switch (raw.method, raw.path) {
            case ("POST", FleetProtocol.usageDayPath):
                // Content-Type 必须是 application/json（§4.3）。
                let contentType = (raw.headers["content-type"] ?? "").lowercased()
                guard contentType.contains("application/json") else {
                    response = HubServerResponse.error(415, "Unsupported Media Type", "Content-Type 必须是 application/json")
                    break
                }
                response = await handlers.processReport(raw.body)
            case ("GET", FleetProtocol.usageDayPath):
                response = await handlers.currentSnapshot()
            case ("GET", FleetProtocol.healthPath):
                response = await handlers.health()
            case (_, FleetProtocol.usageDayPath), (_, FleetProtocol.healthPath):
                response = HubServerResponse.error(405, "Method Not Allowed", "方法不支持")
            default:
                response = HubServerResponse.error(404, "Not Found", "路径不在白名单")
            }
            self.respondAndClose(response)
        }
    }

    private func respondAndClose(_ response: HubServerResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        // 日志纪律（§9.3）：不记 body、不记 header，只记尺寸。
        logInfo("[fleet-hub] \(response.status) \(response.body.count) bytes")
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

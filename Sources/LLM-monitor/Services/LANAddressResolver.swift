import Foundation
import Network
import Combine

/// 一个带 IPv4 的网络接口候选。
///
/// 拆成「采集（碰系统接口）」与「挑选（纯函数）」两半：采集那半依赖
/// `getifaddrs` / Network.framework，测试碰不了；挑选那半是纯的，直接喂候选
/// 就能钉住规则（Wi-Fi 优先、回环不算）。
struct LANAddressCandidate: Equatable {
    /// 硬件语义分类，数值越大优先级越高。
    enum Kind: Int, Comparable {
        /// 判不出类型的真实网卡（USB / 雷雳以太网适配器等）。
        case other = 0
        /// 有线以太网。
        case wiredEthernet = 1
        /// Wi-Fi。
        case wifi = 2

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// BSD 接口名（en0 / en1 …）。
    let interface: String
    /// 该接口上的 IPv4。
    let address: String
    /// 硬件类型。
    let kind: Kind
}

/// 本机局域网地址的探测与挑选（设置页「主节点地址」那一格）。
///
/// # 为什么不再「只认 en0」
///
/// 旧口径假设 `en0` 就是 Wi-Fi。碰到「`en0` = 有线网口、Wi-Fi 落在 `en1`」的
/// 机型（Apple Silicon Mac 上很常见：有线口默认占 en0，Wi-Fi 占 en1），整条
/// 链路取不到地址——界面显示「未检测到局域网地址」、复制按钮禁用，而其实有
/// 一个完全可用的地址摆在那里。
///
/// 现在按**硬件语义**挑：Wi-Fi → 有线 → 其它真实网卡。
///
/// # 三段结构
///
/// 1. `LANAddressResolver.candidates()` —— **采集**：`getifaddrs` 拿到所有带
///    IPv4 的接口，剔掉回环 / 虚拟 / 桥接接口。
/// 2. `LANInterfaceKindResolver` —— **硬件分类**：Network.framework 给出
///    Wi-Fi / 有线的接口类型。分类是**异步**的（monitor 启动后才有第一次
///    更新），所以缓存起来供后台地址采集读取。
/// 3. `LANAddressResolver.preferredLANAddress(_:)` —— **挑选**：纯函数。
enum LANAddressResolver {

    /// 本机局域网 IPv4（按硬件语义挑接口）。
    ///
    /// 拿不到时返回 nil——**不**拿 127.0.0.1 顶替：回环地址只有本机能访问，
    /// 副节点拿它当主节点地址永远连不上（界面会显示「未检测到局域网地址」
    /// 并禁用复制）。
    static func currentLANAddress() -> String? {
        preferredLANAddress(candidates())
    }

    /// 本机带 IPv4 的**真实**网络接口候选（已排除虚拟 / 桥接接口）。
    static func candidates() -> [LANAddressCandidate] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ipv4ByInterface: [String: String] = [:]
        var macByInterface: [String: [UInt8]] = [:]
        var loopbackInterfaces: Set<String> = []
        var upInterfaces: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            // 先推进游标再 continue：循环体里的 `continue` 不会跳到这里。
            cursor = interface.ifa_next
            guard let name = String(validatingUTF8: interface.ifa_name) else { continue }
            if interface.ifa_flags & UInt32(IFF_LOOPBACK) != 0 {
                loopbackInterfaces.insert(name)
            }
            // 没 UP 的接口（没插线的有线口）留着地址也没用：链路层是断的，
            // 别的机器连不上。
            if interface.ifa_flags & UInt32(IFF_UP) != 0 {
                upInterfaces.insert(name)
            }
            guard let ifaAddr = interface.ifa_addr else { continue }
            switch ifaAddr.pointee.sa_family {
            case UInt8(AF_INET):
                let sockaddrIn = ifaAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var addr = sockaddrIn.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                ipv4ByInterface[name] = String(cString: buffer)
            case UInt8(AF_LINK):
                let link = ifaAddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                guard link.sdl_alen == 6 else { continue }
                // sockaddr_dl.sdl_data 是「接口名 + 链路地址 + selector」的可变区。
                // sdl_len 给出实际 sockaddr 长度；先校验边界，再按 sdl_nlen 跳过接口名。
                let dataOffset = MemoryLayout<sockaddr_dl>.size
                    - MemoryLayout.size(ofValue: link.sdl_data)
                let sockaddrLength = Int(link.sdl_len)
                guard sockaddrLength >= dataOffset else { continue }
                let dataLength = sockaddrLength - dataOffset
                let dataPointer = UnsafeRawPointer(ifaAddr).advanced(by: dataOffset)
                let data = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
                guard let mac = Self.linkAddressBytes(
                    sdlData: Array(data),
                    nameLength: Int(link.sdl_nlen),
                    addressLength: Int(link.sdl_alen)
                ) else { continue }
                macByInterface[name] = mac
            default:
                break
            }
        }

        // 候选采集可能由后台工作队列触发，但绝不能等在主线程上：网络类型
        // monitor 的首次回调可能尚未到达。稍后类型变化会再次触发异步扫描。
        let kinds = LANInterfaceKindResolver.shared.snapshot(waitTimeout: 0)
        // 雷雳桥的两条腿（en2/en3…）与 bridge0 同 MAC：那是桥，不是网卡，
        // 地址是桥的临时地址，别的机器连不上。
        let bridgeMAC = macByInterface["bridge0"]
        return ipv4ByInterface
            .compactMap { name, address -> LANAddressCandidate? in
                guard !loopbackInterfaces.contains(name) else { return nil }
                guard upInterfaces.contains(name) else { return nil }
                guard !Self.virtualInterfacePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
                if let mac = macByInterface[name], let bridgeMAC, mac == bridgeMAC, name != "bridge0" {
                    return nil
                }
                return LANAddressCandidate(
                    interface: name,
                    address: address,
                    kind: kinds[name] ?? .other
                )
            }
            .sorted { $0.interface < $1.interface }
    }

    /// 从候选里挑局域网地址：Wi-Fi → 有线 → 其它；同类保持传入顺序（先到先得）。
    ///
    /// 回环地址（127.0.0.1）永远不算——副节点拿它连不上。纯函数，测试直接喂候选。
    static func preferredLANAddress(_ candidates: [LANAddressCandidate]) -> String? {
        candidates
            .filter { $0.address != "127.0.0.1" }
            .max { $0.kind < $1.kind }?   // kind 数值越大优先级越高（Wi-Fi 最高）
            .address
    }

    /// 从 sockaddr_dl 的 `sdl_data` 可变区提取链路地址。
    /// 纯函数用于锁住接口名偏移与截断 sockaddr 的边界行为。
    static func linkAddressBytes(
        sdlData: [UInt8],
        nameLength: Int,
        addressLength: Int
    ) -> [UInt8]? {
        guard nameLength >= 0, addressLength > 0 else { return nil }
        let (end, overflow) = nameLength.addingReportingOverflow(addressLength)
        guard !overflow, end <= sdlData.count else { return nil }
        return Array(sdlData[nameLength..<end])
    }

    /// 虚拟 / 桥接接口名前缀：这些不是局域网网卡（见 `candidates`）。
    static let virtualInterfacePrefixes = [
        "lo", "bridge", "utun", "gif", "stf", "anpi", "ap", "awdl", "llw"
    ]
}

/// 接口硬件类型解析器（Network.framework → 缓存，供后台采集读取）。
///
/// `NWPathMonitor` 的接口类型只在 **path 更新时**给，而且 monitor 启动之后
/// 才有第一次更新（没启动时 `currentPath` 是 `.none`）。地址探测在后台异步采集，
/// 这里常驻三个 monitor，把结果缓存下来并在接口类型变化时触发重新采集：
///
/// - **默认 monitor**：给出系统当前路径上的接口，`NWInterface.type` 是权威的
///   硬件类型；
/// - **`.wifi` monitor**：补上「不是默认路由、但确实是 Wi-Fi」的接口；
/// - **`.wiredEthernet` monitor**：同上，补有线网口。
///
/// 为什么不用 `sysctl NET_RT_IFLIST2` 的 `ifi_type`：macOS 上 Wi-Fi 与有线
/// 都是 `IFT_ETHER`（0x06），区分不出来——只能走 Network.framework。
/// `NWPathMonitor` callbacks run on the resolver's serial queue. Every mutable field,
/// including the one-time `started` transition, is guarded by `condition`; snapshots
/// take the same lock. The monitors are configured once and then only emit callbacks.
/// This is the synchronization contract that makes sharing the process-wide resolver safe.
final class LANInterfaceKindResolver: @unchecked Sendable {
    static let shared = LANInterfaceKindResolver()
    static let didUpdateNotification = Notification.Name("LANInterfaceKindResolver.didUpdate")

    private let defaultMonitor = NWPathMonitor()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let queue = DispatchQueue(label: "com.llm-monitor.lan-interface-kinds")
    private let condition = NSCondition()

    private var started = false
    private var defaultTypes: [String: LANAddressCandidate.Kind] = [:]
    private var wifiInterfaces: Set<String> = []
    private var wiredInterfaces: Set<String> = []
    private var merged: [String: LANAddressCandidate.Kind] = [:]
    private var receivedDefaultUpdate = false

    private init() {}

    /// 启动 monitor（幂等）。
    ///
    /// app 启动时调一次：让第一次 path 更新在「用户打开设置页」之前就落地，
    /// 设置页取地址时不用等。`snapshot` 也会自启动，所以别的调用方不必操心。
    func start() {
        condition.lock()
        let alreadyStarted = started
        started = true
        condition.unlock()
        guard !alreadyStarted else { return }

        defaultMonitor.pathUpdateHandler = { [weak self] path in
            self?.applyDefault(path)
        }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            self?.applyTyped(path, kind: .wifi)
        }
        wiredMonitor.pathUpdateHandler = { [weak self] path in
            self?.applyTyped(path, kind: .wiredEthernet)
        }
        defaultMonitor.start(queue: queue)
        wifiMonitor.start(queue: queue)
        wiredMonitor.start(queue: queue)
    }

    /// 接口名 → 硬件类型快照。
    ///
    /// - Parameter waitTimeout: 还没拿到第一次 path 更新时最多等这么久（秒）。
    ///   0 = 不等。app 启动时预热过，正常情况下缓存已经是热的。
    func snapshot(waitTimeout: TimeInterval) -> [String: LANAddressCandidate.Kind] {
        start()
        condition.lock()
        defer { condition.unlock() }
        // 只等**默认** monitor：它是完整清单的来源（Wi-Fi / 有线 monitor 只补
        // 各自的类型）。等任意一个 monitor 都可能拿到半截缓存。
        if !receivedDefaultUpdate, waitTimeout > 0 {
            let deadline = Date().addingTimeInterval(waitTimeout)
            while !receivedDefaultUpdate, condition.wait(until: deadline) {}
        }
        return merged
    }

    private func applyDefault(_ path: NWPath) {
        var types: [String: LANAddressCandidate.Kind] = [:]
        for interface in path.availableInterfaces {
            types[interface.name] = Self.kind(for: interface.type)
        }
        condition.lock()
        defaultTypes = types
        rebuildLocked()
        receivedDefaultUpdate = true
        condition.broadcast()
        condition.unlock()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
    }

    private func applyTyped(_ path: NWPath, kind: LANAddressCandidate.Kind) {
        let names = Set(path.availableInterfaces.map(\.name))
        condition.lock()
        switch kind {
        case .wifi: wifiInterfaces = names
        case .wiredEthernet: wiredInterfaces = names
        case .other: break
        }
        rebuildLocked()
        condition.broadcast()
        condition.unlock()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
    }

    /// 合并三路来源：默认路径的类型判定打底，Wi-Fi / 有线 monitor 的结果覆盖
    /// ——它们更权威（`.other` 只说明「默认路径没把它算成 Wi-Fi / 有线」）。
    private func rebuildLocked() {
        var merged = defaultTypes
        for name in wiredInterfaces { merged[name] = .wiredEthernet }
        for name in wifiInterfaces { merged[name] = .wifi }
        self.merged = merged
    }

    private static func kind(for type: NWInterface.InterfaceType) -> LANAddressCandidate.Kind {
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        default: return .other
        }
    }
}

/// 设置页使用的异步 LAN 地址缓存。View 求值只读已缓存值；`getifaddrs` 在后台
/// 执行，网络路径或接口类型变化时重新扫描。
@MainActor
final class LANAddressMonitor: ObservableObject {
    @Published private(set) var address: String?

    private var pathMonitor: NWPathMonitor?
    private var interfaceObserver: NSObjectProtocol?
    private var requestGeneration = 0

    func start() {
        guard pathMonitor == nil else {
            refresh()
            return
        }
        LANInterfaceKindResolver.shared.start()
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.llm-monitor.lan-address-path")
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        interfaceObserver = NotificationCenter.default.addObserver(
            forName: LANInterfaceKindResolver.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        requestGeneration &+= 1
        let generation = requestGeneration
        address = nil
        Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                LANAddressResolver.currentLANAddress()
            }.value
            guard let self, self.requestGeneration == generation else { return }
            self.address = value
        }
    }

    func stop() {
        requestGeneration &+= 1
        pathMonitor?.cancel()
        pathMonitor = nil
        if let interfaceObserver {
            NotificationCenter.default.removeObserver(interfaceObserver)
            self.interfaceObserver = nil
        }
    }
}

import XCTest
@testable import LLM_monitor

/// 局域网地址**挑选**规则（`LANAddressResolver.preferredLANAddress`）。
///
/// 这段是纯函数，所以能直接把候选喂进去钉住规则。真正的难点在采集那半
/// （`getifaddrs` + Network.framework），测试碰不了——但采集出来的候选
/// 长什么样、该怎么挑，全在这里定死。
final class LANAddressResolverTests: XCTestCase {

    // MARK: - 优先级

    /// Wi-Fi 优先：有线和 Wi-Fi 同时可用时挑 Wi-Fi。
    ///
    /// 旧口径是「只认 en0」，而 Apple Silicon Mac 上 en0 常是有线口——
    /// Wi-Fi 明明可用（en1）却整条链路取不到地址，界面显示「未检测到局域网
    /// 地址」、复制按钮禁用。
    func testPrefersWiFiOverWired() {
        let candidates = [
            LANAddressCandidate(interface: "en0", address: "10.0.0.5", kind: .wiredEthernet),
            LANAddressCandidate(interface: "en1", address: "192.168.88.27", kind: .wifi)
        ]
        XCTAssertEqual(LANAddressResolver.preferredLANAddress(candidates), "192.168.88.27")
    }

    /// 有线优先于其它：USB / 雷雳以太网适配器判不出类型时排最后。
    func testPrefersWiredOverOther() {
        let candidates = [
            LANAddressCandidate(interface: "en4", address: "169.254.10.2", kind: .other),
            LANAddressCandidate(interface: "en0", address: "10.0.0.5", kind: .wiredEthernet)
        ]
        XCTAssertEqual(LANAddressResolver.preferredLANAddress(candidates), "10.0.0.5")
    }

    /// 只有「其它」类型时照常挑一个——判不出类型不等于不能用。
    func testFallsBackToOtherWhenOnlyKindAvailable() {
        let candidates = [
            LANAddressCandidate(interface: "en4", address: "169.254.10.2", kind: .other)
        ]
        XCTAssertEqual(LANAddressResolver.preferredLANAddress(candidates), "169.254.10.2")
    }

    /// 同类型多个接口时先到先得（采集侧按接口名排序，结果稳定可复现）。
    func testKeepsInputOrderWithinSameKind() {
        let candidates = [
            LANAddressCandidate(interface: "en1", address: "192.168.88.27", kind: .wifi),
            LANAddressCandidate(interface: "en2", address: "192.168.88.28", kind: .wifi)
        ]
        XCTAssertEqual(LANAddressResolver.preferredLANAddress(candidates), "192.168.88.27")
    }

    // MARK: - 回环与空集

    /// 回环地址永远不算：副节点拿它连不上。
    func testNeverPicksLoopback() {
        let candidates = [
            LANAddressCandidate(interface: "lo0", address: "127.0.0.1", kind: .other)
        ]
        XCTAssertNil(LANAddressResolver.preferredLANAddress(candidates))
    }

    /// 回环地址排在最后也不能被选中——哪怕它是唯一一个候选。
    func testNeverPicksLoopbackEvenWhenOnlyCandidate() {
        let candidates = [
            LANAddressCandidate(interface: "lo0", address: "127.0.0.1", kind: .wifi)
        ]
        XCTAssertNil(LANAddressResolver.preferredLANAddress(candidates))
    }

    /// 没有候选 → nil（界面显示「未检测到局域网地址」，禁用复制）。
    func testEmptyCandidatesGiveNil() {
        XCTAssertNil(LANAddressResolver.preferredLANAddress([]))
    }

    // MARK: - 虚拟接口排除

    /// 虚拟 / 桥接接口名一律不进候选（`utun` / `bridge` / `gif` / `awdl` …）。
    func testVirtualInterfacePrefixesAreExcluded() {
        let prefixes = LANAddressResolver.virtualInterfacePrefixes
        for expected in ["lo", "bridge", "utun", "gif", "stf", "anpi", "ap", "awdl", "llw"] {
            XCTAssertTrue(prefixes.contains(expected), "\(expected) 应当是虚拟接口前缀")
        }
        // 真网卡（en*）不能被误伤。
        for name in ["en0", "en1", "en4"] {
            XCTAssertFalse(prefixes.contains { name.hasPrefix($0) }, "\(name) 不该被虚拟前缀命中")
        }
    }

    /// 分类枚举的序：其它 < 有线 < Wi-Fi（`preferredLANAddress` 依赖这个序）。
    func testKindOrdering() {
        XCTAssertLessThan(LANAddressCandidate.Kind.other, LANAddressCandidate.Kind.wiredEthernet)
        XCTAssertLessThan(LANAddressCandidate.Kind.wiredEthernet, LANAddressCandidate.Kind.wifi)
    }

    // MARK: - sockaddr_dl 地址字段

    func testLinkAddressSkipsVariableLengthInterfaceName() {
        let bytes: [UInt8] = Array("en2".utf8) + [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        XCTAssertEqual(
            LANAddressResolver.linkAddressBytes(sdlData: bytes, nameLength: 3, addressLength: 6),
            [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        )
    }

    func testLinkAddressRejectsTruncatedSockaddrData() {
        XCTAssertNil(LANAddressResolver.linkAddressBytes(
            sdlData: [0x65, 0x6e, 0x32, 0x00, 0x11],
            nameLength: 3,
            addressLength: 6
        ))
    }
}

import XCTest
import Foundation
import CryptoKit

// 图标资产副本一致性守门测试，语义与 `scripts/sync-icon-assets.sh --check` 对齐：
// 源资产（Assets/icon-master.png、images/llm-quota-730-2-dark.svg）与 SwiftPM
// 打包副本必须是忠实导出——svg 逐字节一致；icon-master.png 是 master 的 256px
// 降采样（运行时只绘制进 128px 位图、显示 22–24pt，1024px 母版保留给
// generate-icns.sh），测试用同一 sips 管线重生成后逐字节比对。sidecar 两行分别
// 记录 master png 与 AppIcon.icns 的 sha256：前者 == 当前 master（icns 新鲜度判据），
// 后者 == 现存 icns 内容（截断/损坏的 icns 不再全绿，FIX10）。
// 曾发生过 icns 停留在旧版多日无人发现的 drift；本测试变红时，先运行
// ./scripts/sync-icon-assets.sh 重新同步并提交，而不是手工逐处修副本。
final class IconAssetSyncTests: XCTestCase {

    // #filePath 上溯到仓库根：文件位于仓库根下 Tests/LLMMonitorTests/ 内，
    // 删除「文件名 / LLMMonitorTests / Tests」三级后即为仓库根。
    // Assets/ 与 images/ 在包外，直接 FileManager 读取即可，不走 Bundle。
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → Tests/LLMMonitorTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → 仓库根
    }

    // 非源码检出场景（无 Assets/，例如只随测试包分发的场景）无法校验仓库内资产，跳过。
    private func requireAssetsRoot() throws -> URL {
        let root = repoRoot()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets").path),
            "仓库根下无 Assets/（非源码检出场景），跳过图标资产一致性校验（computed root: \(root.path)）"
        )
        return root
    }

    func testIconAssetCopiesMatchSource() throws {
        let root = try requireAssetsRoot()
        let fm = FileManager.default

        // (a) IconPreview png 副本 == master 的 256px 降采样（副本结构性无法消除，
        //     且有意降采样而非逐字节拷贝；判定管线与 sync 脚本相同：sips 重生成
        //     后逐字节比对，同机同工具链下确定）。
        let masterPNGURL = root.appendingPathComponent("Assets/icon-master.png")
        let masterPNG = try Data(contentsOf: masterPNGURL)
        let previewPNG = try Data(contentsOf: root
            .appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/icon-master.png"))

        let regeneratedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-master-preview-check-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: regeneratedURL) }
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-Z", "256", masterPNGURL.path, "--out", regeneratedURL.path]
        try sips.run()
        sips.waitUntilExit()
        XCTAssertEqual(sips.terminationStatus, 0, "sips 降采样重生成失败，IconPreview 副本无法校验")
        let regeneratedPNG = try Data(contentsOf: regeneratedURL)
        XCTAssertEqual(regeneratedPNG, previewPNG, "IconPreview/icon-master.png 与 master 的 256px 降采样不一致，先跑 ./scripts/sync-icon-assets.sh")

        // (b) 设计稿 svg 两副本逐字节一致。
        let designSVG = try Data(contentsOf: root.appendingPathComponent("images/llm-quota-730-2-dark.svg"))
        let previewSVG = try Data(contentsOf: root
            .appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/llm-quota-730-2-dark.svg"))
        XCTAssertEqual(designSVG, previewSVG, "images/llm-quota-730-2-dark.svg 与 IconPreview 副本不一致，先跑 ./scripts/sync-icon-assets.sh")

        // (c) 回退 icns 必须存在；sidecar（sha256sum 兼容，两行 <sha256>␣␣<路径>）
        //     第一行 == 当前 master png 的 sha256（icns 由当前 master 生成，跨机器
        //     稳定的判据），第二行 == 现存 icns 的 sha256（FIX10：截断/损坏的 icns
        //     不再只凭存在性蒙混过关）。
        let icnsURL = root.appendingPathComponent("Sources/LLM-monitor/Resources/AppIcon.icns")
        XCTAssertTrue(
            fm.fileExists(atPath: icnsURL.path),
            "回退图标 Sources/LLM-monitor/Resources/AppIcon.icns 不存在"
        )
        let sidecar = try String(contentsOfFile: root.appendingPathComponent("Assets/AppIcon.icns.source.sha256").path,
                                  encoding: .utf8)
        let records = Self.parseSha256sumSidecar(sidecar)
        let currentMaster = Self.sha256Hex(masterPNG)
        XCTAssertEqual(
            records["Assets/icon-master.png"], currentMaster,
            "AppIcon.icns 已过期：sidecar 记录的 master sha256 与当前 Assets/icon-master.png 不一致，先跑 ./scripts/sync-icon-assets.sh"
        )
        let icnsData = try Data(contentsOf: icnsURL)
        XCTAssertEqual(
            records["Sources/LLM-monitor/Resources/AppIcon.icns"], Self.sha256Hex(icnsData),
            "AppIcon.icns 内容与 sidecar 记录不一致（icns 可能被截断/损坏），先跑 ./scripts/sync-icon-assets.sh"
        )
    }

    /// FIX10: 在临时目录复刻仓库结构，跑真正的 `scripts/sync-icon-assets.sh --check`：
    /// 正常路径通过；icns 被截断（模拟 iconutil 中途失败的残缺产物）后 --check 必须
    /// 失败并指认 icns 内容 DRIFT。脚本判定逻辑改动时本测试同步兜底。
    func testSyncCheckDetectsTruncatedIcns() throws {
        let root = try requireAssetsRoot()
        let fm = FileManager.default

        let fixture = fm.temporaryDirectory
            .appendingPathComponent("icon-sync-fixture-\(UUID().uuidString)", isDirectory: true)
        for sub in ["Assets", "images", "scripts", "Sources/LLM-monitor/Resources/IconPreview"] {
            try fm.createDirectory(at: fixture.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: fixture) }

        // 源资产与脚本副本（脚本以自身位置推导 ROOT_DIR，故拷进 fixture/scripts/）
        let fixtureMaster = fixture.appendingPathComponent("Assets/icon-master.png")
        try Data(contentsOf: root.appendingPathComponent("Assets/icon-master.png")).write(to: fixtureMaster)
        try Data(contentsOf: root.appendingPathComponent("images/llm-quota-730-2-dark.svg"))
            .write(to: fixture.appendingPathComponent("images/llm-quota-730-2-dark.svg"))
        for script in ["sync-icon-assets.sh", "generate-icns.sh"] {
            let dst = fixture.appendingPathComponent("scripts/\(script)")
            try Data(contentsOf: root.appendingPathComponent("scripts/\(script)")).write(to: dst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        // 打包副本：与 --check 内部相同的 sips 管线生成 png，svg 逐字节拷贝
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-Z", "256", fixtureMaster.path,
                          "--out", fixture.appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/icon-master.png").path]
        try sips.run()
        sips.waitUntilExit()
        XCTAssertEqual(sips.terminationStatus, 0, "sips 降采样失败，fixture 无法搭建")
        try Data(contentsOf: root.appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/llm-quota-730-2-dark.svg"))
            .write(to: fixture.appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/llm-quota-730-2-dark.svg"))

        // icns 取仓库现存版本；sidecar 按新格式记录 master + icns 两个 sha256
        let fixtureICNS = fixture.appendingPathComponent("Sources/LLM-monitor/Resources/AppIcon.icns")
        let icnsData = try Data(contentsOf: root.appendingPathComponent("Sources/LLM-monitor/Resources/AppIcon.icns"))
        try icnsData.write(to: fixtureICNS)
        let sidecar = "\(Self.sha256Hex(try Data(contentsOf: fixtureMaster)))  Assets/icon-master.png\n"
            + "\(Self.sha256Hex(icnsData))  Sources/LLM-monitor/Resources/AppIcon.icns\n"
        try sidecar.write(to: fixture.appendingPathComponent("Assets/AppIcon.icns.source.sha256"),
                          atomically: true, encoding: .utf8)

        let script = fixture.appendingPathComponent("scripts/sync-icon-assets.sh")
        // 正常路径：--check 通过
        let (okStatus, okOutput) = try Self.runBash(script, arguments: ["--check"])
        XCTAssertEqual(okStatus, 0, "fixture 正常路径 --check 应通过：\(okOutput)")

        // 截断 icns → --check 必须失败并报告 icns 内容 DRIFT
        let truncated = Data(icnsData.prefix(icnsData.count - 64))
        try truncated.write(to: fixtureICNS)
        let (badStatus, badOutput) = try Self.runBash(script, arguments: ["--check"])
        XCTAssertNotEqual(badStatus, 0, "icns 被截断后 --check 必须失败：\(badOutput)")
        XCTAssertTrue(
            badOutput.contains("AppIcon.icns 内容与 sidecar 记录不一致"),
            "应报告 icns 内容 DRIFT：\(badOutput)"
        )
    }

    // MARK: - 工具

    /// 解析 sha256sum 兼容 sidecar（每行 `<sha256>␣␣<相对仓库根路径>`）为 [路径: sha]。
    private static func parseSha256sumSidecar(_ content: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 {
                map[String(fields[1])] = String(fields[0])
            }
        }
        return map
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 以 /bin/bash 运行脚本，合并 stdout/stderr 返回（退出码, 输出）。
    private static func runBash(_ script: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

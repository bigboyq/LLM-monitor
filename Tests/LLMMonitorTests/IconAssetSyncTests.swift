import XCTest
import Foundation
import CryptoKit

// 图标资产副本一致性守门测试，语义与 `scripts/sync-icon-assets.sh --check` 对齐：
// 源资产（Assets/icon-master.png、images/llm-quota-730-2-dark.svg）与 SwiftPM
// 打包副本必须是忠实导出——svg 逐字节一致；icon-master.png 是 master 的 256px
// 降采样（运行时只绘制进 128px 位图、显示 22–24pt，1024px 母版保留给
// generate-icns.sh），测试用同一 sips 管线重生成后逐字节比对。且 sidecar 记录的
// master sha256 必须等于当前 master（这是回退 AppIcon.icns 新鲜度的确定性判据）。
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

        // (c) 回退 icns 必须存在，且 sidecar 记录的 sha256 == 当前 master png 的
        //     sha256（即 icns 由当前版本的 master 生成，跨机器稳定的判据）。
        XCTAssertTrue(
            fm.fileExists(atPath: root.appendingPathComponent("Sources/LLM-monitor/Resources/AppIcon.icns").path),
            "回退图标 Sources/LLM-monitor/Resources/AppIcon.icns 不存在"
        )
        // sidecar 为 sha256sum 兼容格式（<sha256>␣␣<路径>），只取第一行首列。
        let sidecar = try String(contentsOfFile: root.appendingPathComponent("Assets/AppIcon.icns.source.sha256").path,
                                  encoding: .utf8)
        let firstLine = sidecar.split(separator: "\n").first ?? ""
        let recorded = firstLine.split(separator: " ").first.map(String.init) ?? ""
        let current = SHA256.hash(data: masterPNG).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recorded, current, "AppIcon.icns 已过期：sidecar 哈希与当前 Assets/icon-master.png 不一致，先跑 ./scripts/sync-icon-assets.sh")
    }
}

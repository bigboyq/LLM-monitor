import XCTest
import Foundation
import CryptoKit

// 图标资产副本一致性守门测试，语义与 `scripts/sync-icon-assets.sh --check` 对齐：
// 源资产（Assets/icon-master.png、images/llm-quota-730-2-dark.svg）与 SwiftPM
// 打包副本必须逐字节一致，且 sidecar 记录的 master sha256 必须等于当前 master
// （这是回退 AppIcon.icns 新鲜度的确定性判据）。曾发生过 icns 停留在旧版多日
// 无人发现的 drift；本测试变红时，先运行 ./scripts/sync-icon-assets.sh 重新
// 同步并提交，而不是手工逐处修副本。
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

        // (a) master png 两副本逐字节一致（SwiftPM .copy 资源副本结构性无法消除，只能钉住）。
        let masterPNG = try Data(contentsOf: root.appendingPathComponent("Assets/icon-master.png"))
        let previewPNG = try Data(contentsOf: root
            .appendingPathComponent("Sources/LLM-monitor/Resources/IconPreview/icon-master.png"))
        XCTAssertEqual(masterPNG, previewPNG, "Assets/icon-master.png 与 IconPreview 副本不一致，先跑 ./scripts/sync-icon-assets.sh")

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

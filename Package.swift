// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LLM-monitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLM-monitor", targets: ["LLM-monitor"])
    ],
    targets: [
        .executableTarget(
            name: "LLM-monitor",
            path: "Sources/LLM-monitor",
            exclude: ["Resources/AppIcon.icns"],
            resources: [
                .process("Resources/BrandLogos"),
                .process("Resources/ModelPricing.json"),
                .copy("Resources/IconPreview/llm-quota-730-2-dark.svg"),
                .copy("Resources/IconPreview/icon-master.png")
            ],
            swiftSettings: [
                // release 用 -Osize 优先体积：SwiftUI 泛型特化在 -O 下代码膨胀明显。
                // debug/test 不受影响（默认 -Onone）。
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LLMMonitorTests",
            dependencies: ["LLM-monitor"],
            path: "Tests/LLMMonitorTests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)

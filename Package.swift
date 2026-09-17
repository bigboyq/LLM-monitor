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
                .copy("Resources/IconPreview/llm-quota-730-2-dark.svg")
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

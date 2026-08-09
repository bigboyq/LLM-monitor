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
                .process("Resources/BrandLogos")
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

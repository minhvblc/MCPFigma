// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MCPFigma",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "MCPFigmaCore", targets: ["MCPFigmaCore"]),
        .executable(name: "mcp-figma", targets: ["MCPFigmaServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(name: "MCPFigmaCore"),
        .executableTarget(
            name: "MCPFigmaServer",
            dependencies: [
                "MCPFigmaCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "MCPFigmaCoreTests",
            dependencies: ["MCPFigmaCore"]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mcp_client",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "mcp_client",
            path: "Sources/mcp_client"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPATool",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "IPATool",
            path: "Sources/IPATool"
        )
    ]
)
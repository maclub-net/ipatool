// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPATool",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IPAToolKit",
            path: "Sources/IPAToolKit"
        ),
        .executableTarget(
            name: "IPATool",
            dependencies: ["IPAToolKit"],
            path: "Sources/IPATool"
        ),
        .executableTarget(
            name: "ipatool-cli",
            dependencies: [
                "IPAToolKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ipatool-cli"
        ),
    ]
)

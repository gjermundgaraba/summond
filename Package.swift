// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "keybindd",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "keybindd",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TOML", package: "swift-toml"),
            ],
            path: "Sources/Keybindd"
        ),
        .testTarget(
            name: "KeybinddTests",
            dependencies: ["keybindd"],
            path: "Tests/KeybinddTests"
        ),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "keybindd",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "KeybinddCore", targets: ["KeybinddCore"])
  ],
  targets: [
    .target(
      name: "KeybinddCore",
      path: "Sources/KeybinddCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "KeybinddTests",
      dependencies: ["KeybinddCore"],
      path: "Tests/KeybinddTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)

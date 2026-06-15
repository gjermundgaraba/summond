// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "summond",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "SummondCore", targets: ["SummondCore"])
  ],
  targets: [
    .target(
      name: "SummondCore",
      path: "Sources/SummondCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "SummondTests",
      dependencies: ["SummondCore"],
      path: "Tests/SummondTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)

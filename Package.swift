// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "spinoff",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "spinoff", targets: ["spinoff"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
  ],
  targets: [
    .executableTarget(
      name: "spinoff",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
    .testTarget(
      name: "spinoffTests",
      dependencies: [
        "spinoff",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
  ]
)

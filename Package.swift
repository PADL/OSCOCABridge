// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "OSCOCABridge",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(
      name: "OSCOCABridge",
      targets: ["OSCOCABridge"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/SwiftOCA", branch: "main"),
    .package(url: "https://github.com/PADL/SocketAddress", from: "0.4.5"),
    .package(url: "https://github.com/PADL/IORingSwift", from: "0.1.9"),
    .package(url: "https://github.com/orchetect/OSCKit", branch: "main"),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/lhoward/AsyncExtensions", from: "0.9.0"),
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.20.0"),
  ],
  targets: [
    .target(
      name: "OSCOCABridge",
      dependencies: [
        "AsyncExtensions",
        "SocketAddress",
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "OSCKitCore", package: "OSCKit"),
        .product(name: "IORing", package: "IORingSwift", condition: .when(platforms: [.linux])),
        .product(
          name: "FlyingSocks",
          package: "FlyingFox",
          condition: .when(platforms: [.macOS, .iOS, .android])
        ),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .executableTarget(
      name: "OSCOCADevice",
      dependencies: [
        "OSCOCABridge",
      ],
      path: "Examples/OSCOCADevice"
    ),
  ]
)

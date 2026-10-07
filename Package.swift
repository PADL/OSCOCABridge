// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "OSCOCABridge",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(
      name: "OSCOCABridge",
      targets: ["OSCOCABridge"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/SwiftOCA", branch: "property-key-path-tables"),
    .package(url: "https://github.com/PADL/SocketAddress", from: "0.4.5"),
    .package(url: "https://github.com/PADL/IORingSwift", from: "2.1.3"),
    .package(url: "https://github.com/orchetect/swift-osc-core", branch: "main"),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/sideeffect-io/AsyncExtensions", from: "0.7.0"),
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.20.0"),
  ],
  targets: [
    .target(
      name: "OSCOCABridge",
      dependencies: [
        "AsyncExtensions",
        "SocketAddress",
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "SwiftOSCCore", package: "swift-osc-core"),
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

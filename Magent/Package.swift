// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Magent",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "Magent", targets: ["Magent"]),
    .executable(name: "WTinyLFUCacheBenchmark", targets: ["WTinyLFUCacheBenchmark"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
    .package(url: "https://github.com/orlandos-nl/DNSClient.git", exact: "2.7.0"),
  ],
  targets: [
    .target(
      name: "Magent",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "DNSClient", package: "DNSClient"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "Sources"
    ),
    .testTarget(
      name: "MagentTests",
      dependencies: [
        "Magent",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOEmbedded", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "Tests",
      exclude: [
        "Core/WTinyLFUCacheBenchmark.swift"
      ]
    ),
    .executableTarget(
      name: "WTinyLFUCacheBenchmark",
      dependencies: ["Magent"],
      path: "Tests/Core",
      exclude: [
        "MagentCoreTests.swift",
        "WTinyLFUCacheStressTests.swift",
        "WTinyLFUCacheTests.swift",
      ],
      sources: ["WTinyLFUCacheBenchmark.swift"]
    ),
  ]
)

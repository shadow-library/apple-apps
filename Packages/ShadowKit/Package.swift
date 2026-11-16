// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "ShadowKit",
  platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26), .tvOS(.v26), .visionOS(.v26)],
  products: [
    .library(name: "ShadowCore", targets: ["ShadowCore"]),
    .library(name: "ShadowNetworking", targets: ["ShadowNetworking"]),
    .library(name: "ShadowKeychain", targets: ["ShadowKeychain"]),
    .library(name: "ShadowStore", targets: ["ShadowStore"]),
    .library(name: "ShadowSync", targets: ["ShadowSync"]),
    .library(name: "ShadowAI", targets: ["ShadowAI"]),
    .library(name: "ShadowDesignSystem", targets: ["ShadowDesignSystem"]),
    .library(name: "ShadowTestSupport", targets: ["ShadowTestSupport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
  ],
  targets: [
    .target(name: "ShadowCore", swiftSettings: swiftSettings),
    .target(name: "ShadowNetworking", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .target(name: "ShadowKeychain", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .target(name: "ShadowStore", dependencies: ["ShadowCore", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: swiftSettings),
    .target(name: "ShadowSync", dependencies: ["ShadowCore", "ShadowStore", "ShadowKeychain", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: swiftSettings),
    .target(name: "ShadowAI", dependencies: ["ShadowCore", "ShadowNetworking"], swiftSettings: swiftSettings),
    .target(name: "ShadowDesignSystem", swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]),
    .target(name: "ShadowTestSupport", dependencies: ["ShadowCore", "ShadowNetworking", "ShadowKeychain", "ShadowStore", "ShadowSync", "ShadowAI"], swiftSettings: swiftSettings),

    .testTarget(name: "ShadowCoreTests", dependencies: ["ShadowCore", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowNetworkingTests", dependencies: ["ShadowNetworking", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowKeychainTests", dependencies: ["ShadowKeychain", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowStoreTests", dependencies: ["ShadowStore", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowSyncTests", dependencies: ["ShadowSync", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowAITests", dependencies: ["ShadowAI", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowDesignSystemTests", dependencies: ["ShadowDesignSystem"], swiftSettings: swiftSettings),
  ]
)

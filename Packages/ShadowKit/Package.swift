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
    .library(name: "ShadowDesignSystem", targets: ["ShadowDesignSystem"]),
    .library(name: "ShadowTestSupport", targets: ["ShadowTestSupport"]),
  ],
  targets: [
    .target(name: "ShadowCore", swiftSettings: swiftSettings),
    .target(name: "ShadowNetworking", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .target(name: "ShadowKeychain", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .target(name: "ShadowDesignSystem", swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)]),
    .target(name: "ShadowTestSupport", dependencies: ["ShadowNetworking", "ShadowKeychain"], swiftSettings: swiftSettings),

    .testTarget(name: "ShadowCoreTests", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowNetworkingTests", dependencies: ["ShadowNetworking", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowKeychainTests", dependencies: ["ShadowKeychain", "ShadowTestSupport"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowDesignSystemTests", dependencies: ["ShadowDesignSystem"], swiftSettings: swiftSettings),
  ]
)

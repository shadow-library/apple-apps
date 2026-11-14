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
    .library(name: "ShadowTestSupport", targets: ["ShadowTestSupport"]),
  ],
  targets: [
    .target(name: "ShadowCore", swiftSettings: swiftSettings),
    .target(name: "ShadowNetworking", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .target(name: "ShadowTestSupport", dependencies: ["ShadowNetworking"], swiftSettings: swiftSettings),

    .testTarget(name: "ShadowCoreTests", dependencies: ["ShadowCore"], swiftSettings: swiftSettings),
    .testTarget(name: "ShadowNetworkingTests", dependencies: ["ShadowNetworking", "ShadowTestSupport"], swiftSettings: swiftSettings),
  ]
)

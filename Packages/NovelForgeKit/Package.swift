// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "NovelForgeKit",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "NovelForgeCore", targets: ["NovelForgeCore"])
  ],
  dependencies: [
    .package(path: "../ShadowKit"),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
  ],
  targets: [
    .target(
      name: "NovelForgeCore",
      dependencies: [
        .product(name: "ShadowCore", package: "ShadowKit"),
        .product(name: "ShadowStore", package: "ShadowKit"),
        .product(name: "ShadowAI", package: "ShadowKit"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "NovelForgeCoreTests",
      dependencies: [
        "NovelForgeCore",
        .product(name: "ShadowTestSupport", package: "ShadowKit"),
      ],
      swiftSettings: swiftSettings
    ),
  ]
)

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
    .library(name: "NovelForgeCore", targets: ["NovelForgeCore"]),
    .executable(name: "nf-eval", targets: ["NovelForgeEval"]),
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
        .product(name: "ShadowJobs", package: "ShadowKit"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "NovelForgeEval",
      dependencies: [
        "NovelForgeCore",
        .product(name: "ShadowCore", package: "ShadowKit"),
        .product(name: "ShadowStore", package: "ShadowKit"),
        .product(name: "ShadowAI", package: "ShadowKit"),
        .product(name: "ShadowJobs", package: "ShadowKit"),
        .product(name: "ShadowNetworking", package: "ShadowKit"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "NovelForgeCoreTests",
      dependencies: [
        "NovelForgeCore",
        "NovelForgeEval",
        .product(name: "ShadowTestSupport", package: "ShadowKit"),
      ],
      swiftSettings: swiftSettings
    ),
  ]
)

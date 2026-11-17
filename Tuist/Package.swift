// swift-tools-version: 6.2

import PackageDescription

#if TUIST
  import ProjectDescription

  let libraryTargets = [
    "ShadowCore", "ShadowNetworking", "ShadowKeychain", "ShadowStore", "ShadowSync", "ShadowAI", "ShadowDesignSystem", "ShadowTestSupport", "NovelForgeCore",
  ]

  let packageSettings = PackageSettings(
    productTypes: [:],
    targetSettings: Dictionary(
      uniqueKeysWithValues: libraryTargets.map { ($0, Settings.settings(base: ["PRODUCT_BUNDLE_IDENTIFIER": .string("com.shadow.library.\($0.lowercased())")])) }
    )
  )
#endif

let package = Package(
  name: "ShadowLibraryDependencies",
  dependencies: [
    .package(path: "../Packages/ShadowKit"),
    .package(path: "../Packages/NovelForgeKit"),
  ]
)

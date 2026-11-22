// swift-tools-version: 6.2

import PackageDescription

#if TUIST
  import ProjectDescription

  let libraryTargets = [
    "ShadowCore", "ShadowNetworking", "ShadowKeychain", "ShadowStore", "ShadowSync", "ShadowSyncS3", "ShadowSyncOneDrive", "ShadowSyncGoogleDrive", "ShadowSyncCloudKit",
    "ShadowSyncRuntime", "ShadowText", "ShadowAI", "ShadowJobs",
    "ShadowDesignSystem", "ShadowAppShell", "ShadowTestSupport", "NovelForgeCore", "MemoirCore",
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
    .package(path: "../Packages/MemoirKit"),
  ]
)

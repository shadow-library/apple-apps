// swift-tools-version: 6.2

import PackageDescription

#if TUIST
  import ProjectDescription
  import ProjectDescriptionHelpers

  let libraryTargets = [
    "ShadowCore", "ShadowNetworking", "ShadowKeychain", "ShadowStore", "ShadowSync", "ShadowSyncS3", "ShadowSyncOneDrive", "ShadowSyncGoogleDrive", "ShadowSyncCloudKit",
    "ShadowSyncRuntime", "ShadowText", "ShadowAI", "ShadowJobs",
    "ShadowDesignSystem", "ShadowAppShell", "ShadowTestSupport", "NovelForgeCore", "MemoirCore",
  ]

  let targetSettings: [String: SettingsDictionary] = ["NovelForgeCore": .novelForgeCore]

  let packageSettings = PackageSettings(
    productTypes: [:],
    targetSettings: Dictionary(
      uniqueKeysWithValues: libraryTargets.map { target in
        let bundleId: SettingsDictionary = ["PRODUCT_BUNDLE_IDENTIFIER": .string("com.shadow.library.\(target.lowercased())")]
        return (target, Settings.settings(base: bundleId.merging(targetSettings[target] ?? [:]) { $1 }))
      }
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

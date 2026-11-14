// swift-tools-version: 6.2

import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(
    productTypes: [:]
  )
#endif

let package = Package(
  name: "ShadowLibraryDependencies",
  dependencies: [
    .package(path: "../Packages/ShadowKit")
  ]
)

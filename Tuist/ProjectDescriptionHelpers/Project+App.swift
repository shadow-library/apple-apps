import ProjectDescription

extension Project {
  /// Every app in the monorepo is built through this so build settings, signing and test layout stay uniform.
  public static func app(
    name: String,
    displayName: String? = nil,
    platform: AppPlatform,
    bundleIdSuffix: String? = nil,
    category: AppCategory? = nil,
    dependencies: [TargetDependency] = [],
    testDependencies: [TargetDependency] = [],
    includesUITests: Bool = false,
    accentColor: Bool = false,
    infoPlist: [String: Plist.Value] = [:],
    capabilities: [AppCapability] = []
  ) -> Project {
    let bundleId = "\(Organization.appBundleIdPrefix).\(bundleIdSuffix ?? name.lowercased())"
    let resolved = AppCapabilities(capabilities, bundleId: bundleId, platform: platform)
    var defaultInfoPlist: [String: Plist.Value] = [
      "CFBundleDisplayName": .string(displayName ?? name),
      "CFBundleName": .string(displayName ?? name),
      "CFBundleShortVersionString": "$(MARKETING_VERSION)",
      "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
      "UILaunchScreen": [:],
    ]
    if let category { defaultInfoPlist["LSApplicationCategoryType"] = .string(category.rawValue) }
    if let encryption = BuildEnvironment.usesNonExemptEncryption { defaultInfoPlist["ITSAppUsesNonExemptEncryption"] = .boolean(encryption) }
    defaultInfoPlist.merge(resolved.infoPlist) { $1 }

    let app: Target = .target(
      name: name,
      destinations: platform.destinations,
      product: .app,
      bundleId: bundleId,
      deploymentTargets: platform.deploymentTargets,
      infoPlist: .extendingDefault(with: defaultInfoPlist.merging(infoPlist) { $1 }),
      buildableFolders: ["Sources", "Resources"],
      entitlements: resolved.entitlements,
      dependencies: dependencies,
      settings: .shadow(.shadowAppBundle(accentColor: accentColor), capabilities: resolved)
    )

    let tests: Target = .target(
      name: "\(name)Tests",
      destinations: platform.destinations,
      product: .unitTests,
      bundleId: "\(bundleId).tests",
      deploymentTargets: platform.deploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Tests"],
      dependencies: [.target(name: name)] + testDependencies,
      settings: .shadow(.shadowApp)
    )

    let uiTestDestinations = platform.destinations.intersection([.iPhone, .iPad])
    let hasUITests = includesUITests && !uiTestDestinations.isEmpty

    let uiTests: [Target] =
      hasUITests
      ? [
        .target(
          name: "\(name)UITests",
          destinations: uiTestDestinations,
          product: .uiTests,
          bundleId: "\(bundleId).uitests",
          deploymentTargets: .iOS(Organization.minimumOSVersion),
          infoPlist: .default,
          buildableFolders: ["UITests"],
          dependencies: [.target(name: name)],
          settings: .shadow(.shadowApp)
        )
      ]
      : []

    let uiTestSchemes: [Scheme] =
      hasUITests
      ? [
        .scheme(
          name: "\(name)UITests",
          buildAction: .buildAction(targets: [.target(name)]),
          testAction: .targets([.testableTarget(target: .target("\(name)UITests"))], configuration: .debug)
        )
      ]
      : []

    return Project(
      name: name,
      organizationName: Organization.name,
      options: .options(automaticSchemesOptions: .disabled),
      settings: .shadow(.shadowBase),
      targets: [app, tests] + uiTests,
      schemes: [
        .scheme(
          name: name,
          buildAction: .buildAction(targets: [.target(name)]),
          testAction: .targets([.testableTarget(target: .target("\(name)Tests"))], configuration: .debug),
          runAction: .runAction(configuration: .debug, executable: .target(name)),
          archiveAction: .archiveAction(configuration: .release),
          profileAction: .profileAction(configuration: .release, executable: .target(name)),
          analyzeAction: .analyzeAction(configuration: .debug)
        )
      ] + uiTestSchemes
    )
  }
}

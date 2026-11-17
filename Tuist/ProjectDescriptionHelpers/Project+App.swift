import ProjectDescription

extension Project {
  /// Every app in the monorepo is built through this so build settings, signing and test layout stay uniform.
  public static func app(
    name: String,
    platform: AppPlatform,
    bundleIdSuffix: String? = nil,
    dependencies: [TargetDependency] = [],
    testDependencies: [TargetDependency] = [],
    includesUITests: Bool = false,
    infoPlist: [String: Plist.Value] = [:],
    entitlements: Entitlements? = nil
  ) -> Project {
    let bundleId = "\(Organization.appBundleIdPrefix).\(bundleIdSuffix ?? name.lowercased())"
    let defaultInfoPlist: [String: Plist.Value] = [
      "CFBundleDisplayName": .string(name),
      "CFBundleShortVersionString": "$(MARKETING_VERSION)",
      "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
      "UILaunchScreen": [:],
    ]

    let app: Target = .target(
      name: name,
      destinations: platform.destinations,
      product: .app,
      bundleId: bundleId,
      deploymentTargets: platform.deploymentTargets,
      infoPlist: .extendingDefault(with: defaultInfoPlist.merging(infoPlist) { $1 }),
      buildableFolders: ["Sources", "Resources"],
      entitlements: entitlements,
      dependencies: dependencies,
      settings: .shadow(.shadowApp)
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

import ProjectDescription

extension Project {
  /// Every app in the monorepo is built through this so build settings, signing and test layout stay uniform.
  public static func app(
    name: String,
    platform: AppPlatform,
    bundleIdSuffix: String? = nil,
    dependencies: [TargetDependency] = [],
    testDependencies: [TargetDependency] = [],
    infoPlist: [String: Plist.Value] = [:],
    entitlements: Entitlements? = nil
  ) -> Project {
    let bundleId = "\(Organization.bundleIdPrefix).\(bundleIdSuffix ?? name.lowercased())"
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

    return Project(
      name: name,
      organizationName: Organization.name,
      options: .options(automaticSchemesOptions: .disabled),
      settings: .shadow(.shadowBase),
      targets: [app, tests],
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
      ]
    )
  }
}

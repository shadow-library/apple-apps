import ProjectDescription

extension SettingsDictionary {
  static let shadowBase: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "ENABLE_MODULE_VERIFIER": "YES",
    "DEAD_CODE_STRIPPING": "YES",
    "DEVELOPMENT_TEAM": .string(Organization.developmentTeam),
    "CODE_SIGN_STYLE": "Automatic",
  ]

  static let shadowApp: SettingsDictionary = shadowBase.merging([
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "MARKETING_VERSION": "1.0.0",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
  ]) { $1 }
}

extension Settings {
  static func shadow(_ base: SettingsDictionary, capabilities: AppCapabilities? = nil) -> Settings {
    .settings(
      base: base.merging(capabilities?.settings ?? [:]) { $1 },
      configurations: [
        .debug(name: .debug, settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG"]),
        .release(name: .release, settings: ["SWIFT_COMPILATION_MODE": "wholemodule"]),
      ]
    )
  }
}

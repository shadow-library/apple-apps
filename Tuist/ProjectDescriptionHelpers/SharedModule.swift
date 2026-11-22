import ProjectDescription

public enum SharedModule: String, CaseIterable {
  case core = "ShadowCore"
  case networking = "ShadowNetworking"
  case keychain = "ShadowKeychain"
  case store = "ShadowStore"
  case sync = "ShadowSync"
  case syncS3 = "ShadowSyncS3"
  case syncOneDrive = "ShadowSyncOneDrive"
  case syncGoogleDrive = "ShadowSyncGoogleDrive"
  case syncCloudKit = "ShadowSyncCloudKit"
  case syncRuntime = "ShadowSyncRuntime"
  case text = "ShadowText"
  case ai = "ShadowAI"
  case jobs = "ShadowJobs"
  case designSystem = "ShadowDesignSystem"
  case appShell = "ShadowAppShell"
  case testSupport = "ShadowTestSupport"
}

extension TargetDependency {
  public static func shared(_ module: SharedModule) -> TargetDependency {
    .external(name: module.rawValue)
  }
}

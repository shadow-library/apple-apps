import ProjectDescription

public enum SharedModule: String, CaseIterable {
  case core = "ShadowCore"
  case networking = "ShadowNetworking"
  case keychain = "ShadowKeychain"
  case store = "ShadowStore"
  case sync = "ShadowSync"
  case ai = "ShadowAI"
  case jobs = "ShadowJobs"
  case designSystem = "ShadowDesignSystem"
  case testSupport = "ShadowTestSupport"
}

extension TargetDependency {
  public static func shared(_ module: SharedModule) -> TargetDependency {
    .external(name: module.rawValue)
  }
}

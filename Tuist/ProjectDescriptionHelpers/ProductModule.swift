import ProjectDescription

public enum ProductModule: String, CaseIterable {
  case novelForgeCore = "NovelForgeCore"
  case memoirCore = "MemoirCore"
}

extension TargetDependency {
  public static func product(_ module: ProductModule) -> TargetDependency {
    .external(name: module.rawValue)
  }
}

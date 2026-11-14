struct CatalogLaunchConfiguration: Equatable, Sendable {
  static let componentFlag = "-component"
  static let appearanceFlag = "-appearance"

  let page: CatalogPage?
  let appearance: CatalogAppearance?

  var isAutomated: Bool { page != nil || appearance != nil }

  init(page: CatalogPage? = nil, appearance: CatalogAppearance? = nil) {
    self.page = page
    self.appearance = appearance
  }

  init(arguments: [String]) {
    page = Self.value(of: Self.componentFlag, in: arguments).flatMap(CatalogPage.init(id:))
    appearance = Self.value(of: Self.appearanceFlag, in: arguments).flatMap { CatalogAppearance(rawValue: $0.lowercased()) }.flatMap { $0 == .system ? nil : $0 }
  }

  private static func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.lastIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("-") ? nil : value
  }
}

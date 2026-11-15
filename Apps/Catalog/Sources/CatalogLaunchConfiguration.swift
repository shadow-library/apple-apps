import Foundation

struct CatalogLaunchConfiguration: Equatable, Sendable {
  static let componentFlag = "-component"
  static let appearanceFlag = "-appearance"
  static let snapshotFlag = "-snapshot"
  static let listComponentsFlag = "-list-components"
  static let scrollFlag = "-scroll"
  static let presentFlag = "-present"
  static let screenFlag = "-screen"

  let page: CatalogPage?
  let appearance: CatalogAppearance?
  let snapshotURL: URL?
  let listsComponents: Bool
  let scrollFraction: Double?
  let presentsSample: Bool
  let screen: String?

  var isAutomated: Bool { page != nil || appearance != nil || snapshotURL != nil }

  init(
    page: CatalogPage? = nil, appearance: CatalogAppearance? = nil, snapshotURL: URL? = nil, listsComponents: Bool = false, scrollFraction: Double? = nil,
    presentsSample: Bool = false, screen: String? = nil
  ) {
    self.page = page
    self.appearance = appearance
    self.snapshotURL = snapshotURL
    self.listsComponents = listsComponents
    self.scrollFraction = scrollFraction
    self.presentsSample = presentsSample
    self.screen = screen
  }

  init(arguments: [String]) {
    page = Self.value(of: Self.componentFlag, in: arguments).flatMap(CatalogPage.init(id:))
    appearance = Self.value(of: Self.appearanceFlag, in: arguments).flatMap { CatalogAppearance(rawValue: $0.lowercased()) }.flatMap { $0 == .system ? nil : $0 }
    snapshotURL = Self.value(of: Self.snapshotFlag, in: arguments).map { URL(filePath: $0) }
    listsComponents = arguments.contains(Self.listComponentsFlag)
    scrollFraction = Self.value(of: Self.scrollFlag, in: arguments).flatMap { Double($0) }.flatMap { $0.isFinite ? min($0, 1) : nil }
    presentsSample = arguments.contains(Self.presentFlag)
    screen = Self.value(of: Self.screenFlag, in: arguments)?.lowercased()
  }

  private static func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.lastIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("-") ? nil : value
  }
}

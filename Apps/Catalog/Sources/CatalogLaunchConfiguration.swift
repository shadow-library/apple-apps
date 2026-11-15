import Foundation

struct CatalogLaunchConfiguration: Equatable, Sendable {
  static let componentFlag = "-component"
  static let appearanceFlag = "-appearance"
  static let snapshotFlag = "-snapshot"
  static let listComponentsFlag = "-list-components"
  static let scrollFlag = "-scroll"
  static let presentFlag = "-present"
  static let screenFlag = "-screen"
  static let capturePollFlag = "-capture-poll"
  static let defaultCapturePoll = Duration.milliseconds(250)

  let page: CatalogPage?
  let appearance: CatalogAppearance?
  let snapshotURL: URL?
  let listsComponents: Bool
  let scrollFraction: Double?
  let presentsSample: Bool
  let screen: String?
  let capturePoll: Duration

  // A capture accepts two identical frames one poll apart, so the page must finish scrolling within half a poll of its layout settling.
  var scrollSettleDelay: Duration { capturePoll / 2 }

  var isAutomated: Bool { page != nil || appearance != nil || snapshotURL != nil }

  init(
    page: CatalogPage? = nil, appearance: CatalogAppearance? = nil, snapshotURL: URL? = nil, listsComponents: Bool = false, scrollFraction: Double? = nil,
    presentsSample: Bool = false, screen: String? = nil, capturePoll: Duration = defaultCapturePoll
  ) {
    self.page = page
    self.appearance = appearance
    self.snapshotURL = snapshotURL
    self.listsComponents = listsComponents
    self.scrollFraction = scrollFraction
    self.presentsSample = presentsSample
    self.screen = screen
    self.capturePoll = capturePoll
  }

  init(arguments: [String]) {
    page = Self.value(of: Self.componentFlag, in: arguments).flatMap(CatalogPage.init(id:))
    appearance = Self.value(of: Self.appearanceFlag, in: arguments).flatMap { CatalogAppearance(rawValue: $0.lowercased()) }.flatMap { $0 == .system ? nil : $0 }
    snapshotURL = Self.value(of: Self.snapshotFlag, in: arguments).map { URL(filePath: $0) }
    listsComponents = arguments.contains(Self.listComponentsFlag)
    scrollFraction = Self.value(of: Self.scrollFlag, in: arguments).flatMap { Double($0) }.flatMap { $0.isFinite ? min($0, 1) : nil }
    presentsSample = arguments.contains(Self.presentFlag)
    screen = Self.value(of: Self.screenFlag, in: arguments)?.lowercased()
    capturePoll =
      Self.value(of: Self.capturePollFlag, in: arguments).flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? Duration.seconds($0) : nil }
      ?? Self.defaultCapturePoll
  }

  private static func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.lastIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("-") ? nil : value
  }
}

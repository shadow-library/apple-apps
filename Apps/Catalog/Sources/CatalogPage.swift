import Foundation

enum CatalogPage: Hashable, Identifiable, Sendable {
  case tokens
  case component(CatalogComponent)

  static let all: [CatalogPage] = [.tokens] + CatalogComponent.allCases.map(CatalogPage.component)

  var id: String {
    switch self {
    case .tokens: "Tokens"
    case .component(let component): component.id
    }
  }

  var title: String {
    switch self {
    case .tokens: "Tokens"
    case .component(let component): component.title
    }
  }

  var systemImage: String {
    switch self {
    case .tokens: "swatchpalette"
    case .component(let component): component.systemImage
    }
  }

  var group: CatalogGroup {
    switch self {
    case .tokens: .foundations
    case .component(let component): component.group
    }
  }

  var layout: CatalogPageLayout {
    switch self {
    case .tokens: .scroll
    case .component(let component): component.layout
    }
  }

  init?(id: String) {
    guard let page = Self.all.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
    self = page
  }
}

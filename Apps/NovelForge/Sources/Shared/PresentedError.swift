import Foundation
import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct PresentedError: Equatable {
  let headline: String
  let detail: String?

  init(headline: String, detail: String?) {
    self.headline = headline
    self.detail = detail
  }

  init(_ error: any Error, known: (DomainError) -> String? = { _ in nil }) {
    switch error {
    case let domain as DomainError:
      if case .store(let store) = domain {
        self.init(headline: Self.storeHeadline, detail: store.code)
      } else {
        self.init(headline: known(domain) ?? Self.genericHeadline, detail: domain.code)
      }
    case let store as StoreError:
      self.init(headline: Self.storeHeadline, detail: store.code)
    default:
      self.init(headline: Self.genericHeadline, detail: nil)
    }
  }

  var text: Text {
    guard let detail else { return Text(verbatim: headline) }
    var code = AttributedString(detail)
    code.font = Font.caption.monospaced()
    code.foregroundColor = ShadowColor.textSecondary
    return Text(AttributedString("\(headline)\n") + code)
  }

  private static var genericHeadline: String { String(localized: "Something went wrong.", table: "Navigation") }
  private static var storeHeadline: String { String(localized: "Your data could not be read or saved.", table: "Navigation") }
}

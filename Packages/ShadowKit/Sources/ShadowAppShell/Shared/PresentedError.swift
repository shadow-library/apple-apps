import Foundation
import ShadowCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

public struct PresentedError: Equatable {
  public let headline: String
  public let detail: String?

  public init(headline: String, detail: String?) {
    self.headline = headline
    self.detail = detail
  }

  public init(_ error: any Error) {
    switch error {
    case let store as StoreError: self.init(headline: Self.storeHeadline, detail: store.code)
    case let domain as any DomainFailure:
      if let store = domain.storeFailure {
        self.init(store)
      } else {
        self.init(headline: Self.genericHeadline, detail: domain.code)
      }
    default: self.init(headline: Self.genericHeadline, detail: nil)
    }
  }

  public var text: Text {
    guard let detail else { return Text(verbatim: headline) }
    var code = AttributedString(detail)
    code.font = Font.caption.monospaced()
    code.foregroundColor = ShadowColor.textSecondary
    return Text(AttributedString("\(headline)\n") + code)
  }

  public static var genericHeadline: String { String(localized: "Something went wrong.", table: "AppShell", bundle: .module) }
  public static var storeHeadline: String { String(localized: "Your data could not be read or saved.", table: "AppShell", bundle: .module) }
}

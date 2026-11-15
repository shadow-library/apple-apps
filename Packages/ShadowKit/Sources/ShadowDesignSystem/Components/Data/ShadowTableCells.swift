import SwiftUI

public struct ShadowTableIdentifier: View {
  private let identifier: String

  public init(_ identifier: String) {
    self.identifier = identifier
  }

  public var body: some View {
    Text(verbatim: identifier)
      .font(ShadowDensity.current == .touch ? Font.shadow(.body).monospaced() : Font.shadow(.monoBody))
      .shadowTableCell()
      .lineLimit(1)
      .truncationMode(.middle)
      .shadowSkeletonText()
      .help(identifier)
  }
}

public struct ShadowTableNumber: View {
  private let text: Text

  public init(_ text: Text) {
    self.text = text
  }

  public var body: some View {
    text
      .shadowFont(.body)
      .monospacedDigit()
      .shadowTableCell()
      .lineLimit(1)
      .shadowSkeletonText()
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

extension View {
  // Native iPad tables draw every column after the first in secondary, and even `.primary` resolves to it there.
  public func shadowTableCell() -> some View {
    foregroundStyle(ShadowProminenceStyle(.textPrimary))
  }
}

extension Text {
  public func shadowTableHeader() -> Text {
    font(Font.shadow(.subheadline)).fontWeight(.medium).foregroundStyle(ShadowColor.textSecondary)
  }
}

import SwiftUI

public struct ShadowTableIdentifier: View {
  private let identifier: String

  public init(_ identifier: String) {
    self.identifier = identifier
  }

  public var body: some View {
    Text(verbatim: identifier)
      .shadowFont(.monoBody)
      .lineLimit(1)
      .truncationMode(.middle)
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
      .foregroundStyle(.primary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

extension Text {
  public func shadowTableHeader() -> Text {
    font(Font.shadow(.headline)).foregroundStyle(ShadowColor.textSecondary)
  }
}

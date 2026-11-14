import SwiftUI

extension EnvironmentValues {
  @Entry var shadowValidationMessage: Text?
  @Entry var shadowPreviewFieldFocus: Bool?
}

extension View {
  public func shadowValidation(_ message: Text?) -> some View {
    environment(\.shadowValidationMessage, message)
  }

  @_spi(Preview) public func shadowPreviewFieldFocus(_ isFocused: Bool?) -> some View {
    environment(\.shadowPreviewFieldFocus, isFocused)
  }
}

public struct ShadowValidationMessage: View {
  private let message: Text

  public init(_ message: Text) {
    self.message = message
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
      Image(systemName: "exclamationmark.triangle")
        .imageScale(.small)
        .accessibilityHidden(true)
      message
        .fixedSize(horizontal: false, vertical: true)
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.destructiveLabel)
    .accessibilityElement(children: .combine)
  }
}

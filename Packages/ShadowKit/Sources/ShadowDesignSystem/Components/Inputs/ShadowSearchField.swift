import SwiftUI

public struct ShadowSearchField: View {
  private let prompt: LocalizedStringKey
  private let clearLabel: LocalizedStringKey
  @Binding private var text: String

  public init(_ prompt: LocalizedStringKey, text: Binding<String>, clearLabel: LocalizedStringKey) {
    self.prompt = prompt
    self.clearLabel = clearLabel
    _text = text
  }

  public var body: some View {
    TextField(prompt, text: $text)
      .submitLabel(.search)
      .autocorrectionDisabled()
      .shadowFieldChrome(kind: .search, leading: leading, trailing: trailing)
  }

  private var leading: some View {
    Image(systemName: "magnifyingglass")
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var trailing: some View {
    if !text.isEmpty {
      Button {
        text = ""
      } label: {
        Image(systemName: "xmark.circle.fill")
          .frame(minWidth: Spacing.space6, minHeight: Spacing.space6)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(clearLabel)
    }
  }
}

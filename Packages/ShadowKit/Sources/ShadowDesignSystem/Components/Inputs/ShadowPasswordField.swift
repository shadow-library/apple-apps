import SwiftUI

public struct ShadowPasswordField: View {
  private let title: LocalizedStringKey
  private let showLabel: LocalizedStringKey
  private let hideLabel: LocalizedStringKey
  @Binding private var text: String
  @State private var isRevealed = false
  @FocusState private var ownFocus: Bool
  private let externalFocus: FocusState<Bool>.Binding?

  public init(_ title: LocalizedStringKey, text: Binding<String>, showLabel: LocalizedStringKey, hideLabel: LocalizedStringKey, focus: FocusState<Bool>.Binding? = nil) {
    self.title = title
    self.showLabel = showLabel
    self.hideLabel = hideLabel
    _text = text
    externalFocus = focus
  }

  public var body: some View {
    field
      .focused(focus)
      .textContentType(.password)
      .autocorrectionDisabled()
      #if !os(macOS)
        .textInputAutocapitalization(.never)
      #endif
      .shadowField(
        isFocused: focus.wrappedValue,
        trailing: {
          Button(action: toggleReveal) {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
              .frame(minWidth: Spacing.space6, minHeight: Spacing.space6)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isRevealed ? hideLabel : showLabel)
        })
  }

  private var focus: FocusState<Bool>.Binding { externalFocus ?? $ownFocus }

  @ViewBuilder
  private var field: some View {
    if isRevealed {
      TextField(title, text: $text)
    } else {
      SecureField(title, text: $text)
    }
  }

  private func toggleReveal() {
    let wasFocused = focus.wrappedValue
    isRevealed.toggle()
    guard wasFocused else { return }
    Task { focus.wrappedValue = true }
  }
}

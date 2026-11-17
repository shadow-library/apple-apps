import SwiftUI

public struct ShadowTextEditor: View {
  @Binding private var text: String
  private let placeholder: Text
  private let limit: Int?
  private let minHeight: CGFloat?
  let maxHeight: CGFloat?
  private let counter: (ShadowCharacterCount) -> Text

  public init(text: Binding<String>, placeholder: Text, limit: Int? = nil, minHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, counter: @escaping (ShadowCharacterCount) -> Text)
  {
    _text = text
    self.placeholder = placeholder
    self.limit = limit
    self.minHeight = minHeight
    self.maxHeight = maxHeight
    self.counter = counter
  }

  private var count: ShadowCharacterCount { ShadowCharacterCount(text: text, limit: limit) }
  private var horizontalInset: CGFloat { 5 }
  private var verticalInset: CGFloat { ShadowDensity.current == .touch ? 8 : 0 }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      editor
        .shadowFieldChrome(kind: .multiline, leading: EmptyView(), trailing: EmptyView(), isInvalid: count.isOverLimit)
      counterLabel
    }
  }

  private var editor: some View {
    Text(text.isEmpty ? " " : text + "\n")
      .shadowFont(.body)
      .lineSpacing(Spacing.space05)
      .padding(.horizontal, horizontalInset)
      .padding(.vertical, verticalInset)
      .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
      .hidden()
      .accessibilityHidden(true)
      .overlay {
        TextEditor(text: $text)
          .scrollContentBackground(.hidden)
          .scrollDisabled(maxHeight == nil)
          .shadowFont(.body)
          .lineSpacing(Spacing.space05)
          .foregroundStyle(ShadowColor.textPrimary)
          .accessibilityLabel(placeholder)
      }
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          placeholder
            .shadowFont(.body)
            .foregroundStyle(ShadowColor.textPlaceholder)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, -horizontalInset)
  }

  @ViewBuilder
  private var counterLabel: some View {
    let count = count
    if limit != nil {
      if count.isOverLimit {
        ShadowValidationMessage(counter(count))
      } else {
        counter(count)
          .shadowFont(.footnote)
          .monospacedDigit()
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

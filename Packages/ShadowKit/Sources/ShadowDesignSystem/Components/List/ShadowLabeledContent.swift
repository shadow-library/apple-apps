import SwiftUI

public struct ShadowLabeledContent<Content: View>: View {
  private let title: Text
  private let content: Content

  public init(title: Text, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.init(title: Text(titleKey), content: content)
  }

  public var body: some View {
    #if os(macOS)
      LabeledContent {
        content
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
      } label: {
        title
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    #else
      ShadowListRow(
        title: title,
        trailing:
          content
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textSecondary)
          .multilineTextAlignment(.trailing)
      )
    #endif
  }
}

extension ShadowLabeledContent where Content == Text {
  public init(_ titleKey: LocalizedStringKey, value: Text) {
    self.init(titleKey) { value }
  }

  public init(_ titleKey: LocalizedStringKey, value: LocalizedStringKey) {
    self.init(titleKey, value: Text(value))
  }
}

extension ShadowLabeledContent where Content == ShadowIdentifierText {
  public init(_ titleKey: LocalizedStringKey, identifier: String) {
    self.init(titleKey) { ShadowIdentifierText(identifier) }
  }
}

public struct ShadowIdentifierText: View {
  private let identifier: String

  public init(_ identifier: String) {
    self.identifier = identifier
  }

  public var body: some View {
    Text(verbatim: identifier)
      .shadowFont(.monoBody)
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
  }
}

public struct ShadowDetailsForm<Header: View, Content: View>: View {
  private let header: Header
  private let content: Content

  public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.header = header()
    self.content = content()
  }

  public var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: Spacing.space2) {
        header.padding(.horizontal, ShadowListMetrics().horizontalPadding)
        Form { content }
          .formStyle(.columns)
          .frame(maxWidth: .infinity, alignment: .leading)
          .shadowCard()
      }
    #else
      ShadowGroupedSection(content: { content }, header: { header })
    #endif
  }
}

extension ShadowDetailsForm where Header == EmptyView {
  public init(@ViewBuilder content: () -> Content) {
    self.init(content: content, header: { EmptyView() })
  }
}

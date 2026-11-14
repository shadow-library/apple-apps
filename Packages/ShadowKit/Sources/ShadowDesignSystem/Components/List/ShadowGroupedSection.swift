import SwiftUI

// Short static groups only: no swipe actions, selection or lazy loading, and only ShadowListRow and the shadow DisclosureGroupStyle draw separators.
public struct ShadowGroupedSection<Header: View, Content: View, Footer: View>: View {
  private let header: Header
  private let content: Content
  private let footer: Footer

  public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
    self.header = header()
    self.content = content()
    self.footer = footer()
  }

  public var body: some View {
    let cardMetrics = ShadowCardMetrics()
    let inset = ShadowListMetrics().horizontalPadding
    let shape = RoundedRectangle(cornerRadius: cardMetrics.cornerRadius, style: .continuous)
    VStack(alignment: .leading, spacing: Spacing.space2) {
      header.padding(.horizontal, inset)
      VStack(spacing: 0) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(\.shadowMaterialLayer, .content)
      .environment(\.shadowDrawsRowBackground, true)
      .background(ShadowColor.surfaceCard, in: shape)
      .clipShape(shape)
      .overlay {
        if cardMetrics.borderWidth > 0 { shape.strokeBorder(ShadowColor.borderDefault, lineWidth: cardMetrics.borderWidth) }
      }
      footer
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
        .padding(.horizontal, inset)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension ShadowGroupedSection where Header == EmptyView, Footer == EmptyView {
  public init(@ViewBuilder content: () -> Content) {
    self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
  }
}

extension ShadowGroupedSection where Footer == EmptyView {
  public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.init(content: content, header: header, footer: { EmptyView() })
  }
}

extension ShadowGroupedSection where Header == EmptyView {
  public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.init(content: content, header: { EmptyView() }, footer: footer)
  }
}

public struct ShadowRowButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    ShadowRowButtonBody(configuration: configuration)
  }
}

extension ButtonStyle where Self == ShadowRowButtonStyle {
  public static var shadowRow: Self { Self() }
}

private struct ShadowRowButtonBody: View {
  let configuration: ButtonStyleConfiguration

  var body: some View {
    configuration.label
      .background(configuration.isPressed ? ShadowColor.bgPressed : Color.clear)
      .contentShape(.rect)
  }
}

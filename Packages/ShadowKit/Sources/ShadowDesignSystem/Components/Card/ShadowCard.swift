import SwiftUI

public struct ShadowCard<Header: View, Content: View, Footer: View>: View {
  private let header: Header
  private let content: Content
  private let footer: Footer

  public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
    self.header = header()
    self.content = content()
    self.footer = footer()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: ShadowCardMetrics().spacing) {
      header
      content
      footer
    }
    .shadowCard()
  }
}

extension ShadowCard where Header == EmptyView, Footer == EmptyView {
  public init(@ViewBuilder content: () -> Content) {
    self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
  }
}

extension ShadowCard where Footer == EmptyView {
  public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.init(content: content, header: header, footer: { EmptyView() })
  }
}

extension ShadowCard where Header == EmptyView {
  public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.init(content: content, header: { EmptyView() }, footer: footer)
  }
}

public struct ShadowCardHeader<Accessory: View>: View {
  private let title: Text
  private let subtitle: Text?
  private let accessory: Accessory

  public init(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder accessory: () -> Accessory) {
    title = Text(titleKey)
    self.subtitle = subtitle.map { Text($0) }
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        title
          .shadowFont(.headline)
          .foregroundStyle(ShadowColor.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        accessory
      }
      if let subtitle {
        subtitle
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

extension ShadowCardHeader where Accessory == EmptyView {
  public init(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
    self.init(titleKey, subtitle: subtitle) { EmptyView() }
  }
}

struct ShadowCardChrome: ViewModifier {
  var interaction: ShadowButtonInteraction = .idle
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let metrics = ShadowCardMetrics()
    let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    content
      .padding(metrics.padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(\.shadowMaterialLayer, .content)
      .background(fill, in: shape)
      .overlay {
        if metrics.borderWidth > 0 || contrast == .increased { shape.strokeBorder(border, lineWidth: max(metrics.borderWidth, 1)) }
      }
  }

  private var fill: Color {
    interaction == .pressed ? ShadowColor.bgHover : ShadowColor.surfaceCard
  }

  private var border: Color {
    interaction == .idle && contrast != .increased ? ShadowColor.borderDefault : ShadowColor.borderStrong
  }
}

extension View {
  public func shadowCard() -> some View {
    modifier(ShadowCardChrome())
  }
}

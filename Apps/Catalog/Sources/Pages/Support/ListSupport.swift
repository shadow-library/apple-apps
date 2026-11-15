import ShadowDesignSystem
import SwiftUI

struct ListCover: View {
  let book: CatalogBook

  private var isTouch: Bool { ShadowDensity.current == .touch }

  var body: some View {
    RoundedRectangle(cornerRadius: isTouch ? Radius.md : Radius.sm, style: .continuous)
      .fill(LinearGradient(colors: [book.color, book.color.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
      .frame(width: isTouch ? 44 : 28, height: isTouch ? 62 : 40)
      .overlay(alignment: .bottomLeading) {
        Text(verbatim: book.id)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .font(.system(.caption2, weight: .bold))
          .foregroundStyle(ShadowColor.onAccent)
          .padding(Spacing.space1)
      }
      .accessibilityHidden(true)
  }
}

struct UpdateItem: Identifiable, Hashable {
  let id: Int
  let title: String
  let detail: String
  var isUnread: Bool

  static let sample: [UpdateItem] = [
    UpdateItem(id: 43, title: "Chapter 43 · Ash Garden", detail: "The Ninth Archive · just now", isUnread: true),
    UpdateItem(id: 42, title: "Chapter 42 · The Glass Stair", detail: "Yesterday", isUnread: false),
  ]
}

extension Date {
  static let catalogNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 0)) ?? .now

  func catalogAgo(minutes: Int = 0, hours: Int = 0, days: Int = 0) -> Date {
    addingTimeInterval(-Double(minutes * 60 + hours * 3600 + days * 86_400))
  }
}

struct SelectableListBlock<Content: View>: View {
  @Binding var selection: String?
  @ViewBuilder let content: Content
  @State private var height: CGFloat?

  var body: some View {
    let metrics = ShadowCardMetrics()
    let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    List(selection: $selection) {
      content.listSectionSeparator(.hidden)
    }
    .shadowListStyle(.plain)
    .scrollDisabled(true)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .onScrollGeometryChange(for: CGFloat.self) {
      $0.contentSize.height
    } action: { _, newValue in
      if newValue > 0 { height = newValue.rounded(.up) }
    }
    .modifier(MeasuredHeight(height: height))
    .clipShape(shape)
    .overlay {
      if metrics.borderWidth > 0 { shape.strokeBorder(ShadowColor.borderDefault, lineWidth: metrics.borderWidth) }
    }
  }
}

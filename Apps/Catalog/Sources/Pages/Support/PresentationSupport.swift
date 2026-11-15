import ShadowDesignSystem
import SwiftUI

extension EnvironmentValues {
  @Entry var catalogPresentsSample = false
}

extension View {
  func catalogAutoPresent(perform action: @escaping () -> Void) -> some View {
    modifier(CatalogAutoPresent(action: action))
  }

  func catalogAutoPresent(_ isPresented: Binding<Bool>) -> some View {
    catalogAutoPresent { isPresented.wrappedValue = true }
  }
}

private struct CatalogAutoPresent: ViewModifier {
  let action: () -> Void
  @Environment(\.catalogPresentsSample) private var presentsSample
  @State private var hasPresented = false

  func body(content: Content) -> some View {
    content.task {
      guard presentsSample, !hasPresented else { return }
      hasPresented = true
      try? await Task.sleep(for: .milliseconds(600))
      action()
    }
  }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
  case light
  case sepia
  case dark

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .light: "Light"
    case .sepia: "Sepia"
    case .dark: "Dark"
    }
  }

  var systemImage: String {
    switch self {
    case .light: "sun.max"
    case .sepia: "book"
    case .dark: "moon"
    }
  }
}

struct GlassCircleLabel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(width: ShadowMetrics.control(.medium), height: ShadowMetrics.control(.medium))
      .shadowGlass(.regular.interactive(), in: Circle())
      .contentShape(.circle)
  }
}

struct StaticIllustration<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      content
      ShadowBadge("Static illustration", intent: .neutral, systemImage: "photo")
    }
  }
}

struct PresentationBackdrop<Content: View>: View {
  var minHeight: CGFloat = 0
  var alignment: Alignment = .topTrailing
  var coverRows = 1
  @ViewBuilder let content: Content

  private var bandHeight: CGFloat { ShadowMetrics.control(.medium) + Spacing.space3 * 2 }
  private var bandEdge: Edge.Set { alignment.vertical == .bottom ? .bottom : .top }

  var body: some View {
    VStack(spacing: Spacing.space3) {
      ShadowGroupedSection { DemoBookRows() }
      if coverRows > 0 {
        DemoCoverRows(rows: coverRows)
      }
    }
    .padding(Spacing.space3)
    .padding(bandEdge, bandHeight - Spacing.space3)
    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
    .accessibilityHidden(true)
    .overlay(alignment: alignment) {
      content.padding(Spacing.space3)
    }
    .background(ShadowColor.surfaceApp)
    .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous)
        .strokeBorder(ShadowColor.borderSubtle)
    }
  }
}

struct DemoCoverRows: View {
  var rows = 1
  var minimumWidth: CGFloat = 100
  @State private var columns = 3

  var body: some View {
    Grid(horizontalSpacing: Spacing.space2, verticalSpacing: Spacing.space2) {
      ForEach(0..<rows, id: \.self) { row in
        GridRow {
          ForEach(CatalogBook.shelf.dropFirst(row * columns).prefix(columns)) { book in
            CoverArt(book: book)
              .aspectRatio(0.75, contentMode: .fit)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { width in
      columns = min(CatalogBook.shelf.count / max(rows, 1), max(1, Int((width + Spacing.space2) / (minimumWidth + Spacing.space2))))
    }
  }
}

struct StaticMenuItem: Identifiable, Hashable {
  enum Kind: Hashable {
    case action
    case sectionTitle
    case separator
  }

  let id: String
  let kind: Kind
  let title: String
  let systemImage: String?
  let shortcut: KeyboardShortcut?
  let isDestructive: Bool
  let isDisabled: Bool
  let isChecked: Bool
  let isHighlighted: Bool

  static func action(
    _ title: String, systemImage: String? = nil, shortcut: KeyboardShortcut? = nil, isDestructive: Bool = false, isDisabled: Bool = false,
    isChecked: Bool = false, isHighlighted: Bool = false
  ) -> Self {
    Self(
      id: title, kind: .action, title: title, systemImage: systemImage, shortcut: shortcut, isDestructive: isDestructive, isDisabled: isDisabled, isChecked: isChecked,
      isHighlighted: isHighlighted)
  }

  static func sectionTitle(_ title: String) -> Self {
    Self(
      id: "title-\(title)", kind: .sectionTitle, title: title, systemImage: nil, shortcut: nil, isDestructive: false, isDisabled: false, isChecked: false,
      isHighlighted: false)
  }

  static func separator(_ id: String) -> Self {
    Self(
      id: "separator-\(id)", kind: .separator, title: "", systemImage: nil, shortcut: nil, isDestructive: false, isDisabled: false, isChecked: false,
      isHighlighted: false)
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct StaticMenuPanel<Header: View>: View {
  let items: [StaticMenuItem]
  var width: CGFloat?
  @ViewBuilder let header: Header

  private var isTouch: Bool { ShadowDensity.current == .touch }
  private var rowHeight: CGFloat { isTouch ? ShadowMetrics.rowTouch : 22 }
  private var horizontalPadding: CGFloat { isTouch ? Spacing.space4 : Spacing.space2 }
  private var cornerRadius: CGFloat { isTouch ? Radius.panel : Radius.lg }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      ForEach(items) { item in row(item) }
    }
    .padding(.vertical, isTouch ? Spacing.space2 : Spacing.space1)
    .padding(.horizontal, isTouch ? 0 : Spacing.space1)
    .frame(width: width ?? (isTouch ? 270 : 250))
    .shadowGlass(.dense, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .shadowElevation(.e2)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func row(_ item: StaticMenuItem) -> some View {
    switch item.kind {
    case .separator:
      Rectangle()
        .fill(ShadowColor.borderDefault)
        .frame(height: 1)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, Spacing.space1)
    case .sectionTitle:
      Text(verbatim: item.title)
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, Spacing.space2)
        .padding(.bottom, Spacing.space1)
    case .action:
      action(item)
    }
  }

  private func action(_ item: StaticMenuItem) -> some View {
    let foreground: Color =
      item.isHighlighted ? ShadowColor.onAccent : item.isDestructive ? ShadowColor.destructiveLabel : item.isDisabled ? ShadowColor.textTertiary : ShadowColor.textPrimary
    return HStack(spacing: isTouch ? Spacing.space3 : Spacing.space2) {
      Image(systemName: item.isChecked ? "checkmark" : item.systemImage ?? "circle")
        .opacity(item.isChecked || item.systemImage != nil ? 1 : 0)
        .frame(width: isTouch ? 20 : 14)
      Text(verbatim: item.title)
        .lineLimit(1)
      Spacer(minLength: Spacing.space4)
      if let shortcut = item.shortcut {
        Text(verbatim: ShadowShortcutGlyphs.string(for: shortcut))
          .foregroundStyle(item.isHighlighted ? ShadowColor.onAccent : ShadowColor.textTertiary)
      }
    }
    .shadowFont(.body)
    .foregroundStyle(foreground)
    .padding(.horizontal, horizontalPadding)
    .frame(height: rowHeight)
    .background {
      if item.isHighlighted {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(ShadowColor.accent)
      }
    }
  }
}

extension StaticMenuPanel where Header == EmptyView {
  init(items: [StaticMenuItem], width: CGFloat? = nil) {
    self.init(items: items, width: width) { EmptyView() }
  }
}

struct StaticHelpTag: View {
  let text: String

  var body: some View {
    Text(verbatim: text)
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textOnTooltip)
      .padding(.horizontal, Spacing.space2)
      .padding(.vertical, Spacing.space1)
      .background(ShadowColor.surfaceTooltip, in: .rect(cornerRadius: Radius.sm, style: .continuous))
  }
}

import ShadowDesignSystem
import SwiftUI

extension EnvironmentValues {
  @Entry var catalogScrollFraction: Double?
  @Entry var catalogScrollSettleDelay = CatalogLaunchConfiguration.defaultCapturePoll / 2
}

extension View {
  func catalogScrollAnchor() -> some View { modifier(CatalogScrollAnchor()) }
}

private struct CatalogScrollAnchor: ViewModifier {
  @Environment(\.catalogScrollFraction) private var fraction
  @Environment(\.catalogScrollSettleDelay) private var settleDelay
  @State private var position = ScrollPosition()
  @State private var collapsesTitle = false
  @State private var pendingScroll: Task<Void, Never>?

  func body(content: Content) -> some View {
    if let fraction {
      content
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollExtent.self) { geometry in
          let insets = geometry.contentInsets
          return ScrollExtent(topInset: insets.top, overflow: geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height)
        } action: { _, extent in
          scroll(to: fraction, of: extent)
        }
        .catalogCollapsedTitle(collapsesTitle)
    } else {
      content
    }
  }

  private func scroll(to fraction: Double, of extent: ScrollExtent) {
    pendingScroll?.cancel()
    pendingScroll = Task {
      try? await Task.sleep(for: settleDelay)
      guard !Task.isCancelled else { return }
      if fraction > 0 && extent.overflow > 0 { collapsesTitle = true }
      position.scrollTo(y: -extent.topInset + max(extent.overflow, 0) * fraction)
    }
  }
}

private struct ScrollExtent: Equatable {
  let topInset: CGFloat
  let overflow: CGFloat
}

extension View {
  // UIKit keeps the large title expanded when a page that barely scrolls is moved programmatically, while a hand scroll collapses it.
  // Neither an offset nor this mode re-expands a collapsed title, so the capture scrolls only once the page's sizes have settled.
  @ViewBuilder
  fileprivate func catalogCollapsedTitle(_ isCollapsed: Bool) -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(isCollapsed ? .inline : .automatic)
    #else
      self
    #endif
  }
}

extension View {
  func catalogListPage(_ component: CatalogComponent, anchors: [String]) -> some View {
    modifier(CatalogListAnchor(anchors: anchors))
      .background(ShadowColor.surfaceApp)
      .accessibilityIdentifier("component-\(component.id)")
  }
}

private struct CatalogListAnchor: ViewModifier {
  let anchors: [String]
  @Environment(\.catalogScrollFraction) private var fraction
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .scrollPosition($position)
        .task {
          guard let last = anchors.indices.last else { return }
          guard let fraction, fraction > 0 else { return }
          let index = min(last, Int((fraction * Double(last)).rounded()))
          for delay in [0.4, 1.2] {
            try? await Task.sleep(for: .seconds(delay))
            if fraction >= 1 {
              proxy.scrollTo(CatalogListEnd.id, anchor: .bottom)
              position.scrollTo(edge: .bottom)
            } else {
              proxy.scrollTo(anchors[index], anchor: .top)
            }
          }
        }
    }
  }
}

struct CatalogListEnd: View {
  static let id = "catalog-list-end"

  var body: some View {
    Color.clear
      .frame(height: 1)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityHidden(true)
      .id(Self.id)
  }
}

struct StateListSection<Content: View>: View {
  let title: String
  let note: LocalizedStringKey?
  @ViewBuilder let content: Content

  init(_ title: String, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.note = note
    self.content = content()
  }

  var body: some View {
    #if os(macOS)
      Section {
        content
      } header: {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          ShadowSectionHeader(LocalizedStringKey(title))
          if let note { noteText(note) }
        }
      }
      .listSectionSeparator(.hidden)
      .id(title)
    #else
      Section {
        content
      } header: {
        ShadowSectionHeader(LocalizedStringKey(title))
      } footer: {
        if let note { noteText(note) }
      }
      .id(title)
    #endif
  }

  private func noteText(_ note: LocalizedStringKey) -> some View {
    Text(note)
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ComponentPage<Content: View>: View {
  let id: String
  @ViewBuilder let content: Content

  init(component: CatalogComponent, @ViewBuilder content: () -> Content) {
    self.init(id: component.id, content: content)
  }

  init(id: String, @ViewBuilder content: () -> Content) {
    self.id = id
    self.content = content()
  }

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var margin: CGFloat {
    #if os(iOS)
      horizontalSizeClass == .compact ? Spacing.space4 : Spacing.space5
    #else
      Spacing.space5
    #endif
  }

  private var maxColumns: Int {
    #if os(iOS)
      horizontalSizeClass == .compact ? 1 : 3
    #else
      3
    #endif
  }

  private var alignment: Alignment {
    #if os(macOS)
      .top
    #else
      .topLeading
    #endif
  }

  var body: some View {
    ScrollView {
      ShadowAdaptiveColumns(maxColumns: maxColumns, spacing: Spacing.space8) {
        content
      }
      .padding(.horizontal, margin)
      .padding(.vertical, Spacing.space4)
      .frame(maxWidth: .infinity, alignment: alignment)
    }
    .catalogScrollAnchor()
    .background(ShadowColor.surfaceApp)
    .accessibilityIdentifier("component-\(id)")
  }
}

struct StateSection<Content: View>: View {
  let title: LocalizedStringKey
  let note: LocalizedStringKey?
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.note = note
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(title)
          .shadowFont(.headline)
          .foregroundStyle(ShadowColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        if let note {
          Text(note)
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension EnvironmentValues {
  @Entry var catalogTakesSnapshot = false
  @Entry var catalogIsAutomated = false
}

extension View {
  func catalogDemoLocale() -> some View { modifier(CatalogDemoLocale()) }
}

private struct CatalogDemoLocale: ViewModifier {
  static let locale = Locale(identifier: "en_GB")

  @Environment(\.catalogIsAutomated) private var isAutomated

  func body(content: Content) -> some View {
    if isAutomated {
      content.environment(\.locale, Self.locale)
    } else {
      content
    }
  }
}

extension View {
  func catalogSnapshotFocus() -> some View { modifier(CatalogSnapshotFocus()) }
}

private struct CatalogSnapshotFocus: ViewModifier {
  @Environment(\.catalogTakesSnapshot) private var takesSnapshot
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    #if os(macOS)
      content
        .focused($isFocused)
        .task {
          guard takesSnapshot else { return }
          try? await Task.sleep(for: .milliseconds(300))
          isFocused = true
        }
    #else
      content
    #endif
  }
}

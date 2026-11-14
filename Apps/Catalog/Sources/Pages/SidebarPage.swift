import ShadowDesignSystem
import SwiftUI

enum SidebarDemoItem: String, Hashable, CaseIterable, Identifiable {
  case chapters = "Chapters"
  case storyBible = "Story Bible"
  case secrets = "Secrets"
  case canon = "Canon"
  case aiDrafts = "AI drafts"
  case glassAndAsh = "Glass and Ash"
  case saltKings = "Salt Kings"
  case lanternCourt = "The Lantern Court"

  var id: Self { self }

  var systemImage: String {
    switch self {
    case .chapters: "book"
    case .storyBible: "doc.text"
    case .secrets: "lock"
    case .canon: "checkmark.circle"
    case .aiDrafts: "sparkles"
    case .glassAndAsh, .saltKings, .lanternCourt: "books.vertical"
    }
  }

  var badge: ShadowSidebarBadge? {
    switch self {
    case .chapters: .count(DemoChapter.all.count)
    case .secrets: .alert(2)
    default: nil
    }
  }

  static let writing: [Self] = [.chapters, .storyBible, .secrets]
  static let review: [Self] = [.canon, .aiDrafts]
  static let collections: [Self] = [.glassAndAsh, .saltKings, .lanternCourt]
}

struct SidebarPage: View {
  @State private var selection: SidebarDemoItem? = DemoPlatform.opensDetail ? .chapters : nil
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @State private var showsCollections = false

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      List(selection: $selection) {
        DemoOrganisationSwitcher()
        Section {
          ForEach(SidebarDemoItem.writing) { item in SidebarDemoRow(item: item) }
        } header: {
          ShadowSidebarHeader("Writing")
        }
        Section {
          ForEach(SidebarDemoItem.review) { item in SidebarDemoRow(item: item) }
        } header: {
          ShadowSidebarHeader("Review")
        }
        Section(isExpanded: $showsCollections) {
          ForEach(SidebarDemoItem.collections) { item in SidebarDemoRow(item: item) }
        } header: {
          ShadowSidebarHeader("Collections")
        }
      }
      .shadowListStyle(.sidebar)
      .navigationTitle("Novel Forge")
      .shadowColumnWidth(.sidebar)
      .toolbar { CatalogDemoCloseItem() }
    } detail: {
      NavigationStack {
        SidebarDemoDetail(item: selection ?? .chapters)
      }
    }
  }
}

private struct SidebarDemoRow: View {
  let item: SidebarDemoItem

  var body: some View {
    ShadowSidebarLabel(Text(verbatim: item.rawValue), systemImage: item.systemImage, badge: item.badge)
      .tag(item)
  }
}

struct DemoOrganisationSwitcher: View {
  var body: some View {
    Menu {
      Button("Shadow Library · Novel Forge", systemImage: "checkmark") {}
      Button("Shadow Library · Memoir") {}
      Divider()
      Button("Manage organisations…") {}
    } label: {
      HStack(spacing: Spacing.space3) {
        ShadowAvatar(name: "Shadow Library", kind: .organization, size: ShadowDensity.current == .touch ? .medium : .small)
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: "Shadow Library")
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: "Novel Forge")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.up.chevron.down")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Organisation: Shadow Library, Novel Forge")
  }
}

private struct SidebarDemoDetail: View {
  let item: SidebarDemoItem

  var body: some View {
    ScrollView {
      HStack(spacing: Spacing.space2) {
        ForEach(CatalogBook.shelf) { book in CoverArt(book: book, showsTitle: false) }
      }
      .frame(height: 220)
      .padding(.horizontal, Spacing.space2)
      .backgroundExtensionEffect()
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.space6) {
        ShadowGroupedSection {
          ForEach(DemoChapter.all) { chapter in
            ShadowListRow(title: Text(verbatim: chapter.heading), subtitle: Text(verbatim: chapter.title), value: Text(verbatim: chapter.status.rawValue))
          }
        } header: {
          ShadowSectionHeader("Recent")
        }
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .navigationTitle(item.rawValue)
    .shadowScreen(.pushed)
  }
}

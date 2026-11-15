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
      .safeAreaInset(edge: .bottom) {
        DemoAccountMenu(labelStyle: .avatarAndName)
          .padding(.horizontal, DemoLayout.margin)
          .padding(.vertical, Spacing.space3)
      }
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

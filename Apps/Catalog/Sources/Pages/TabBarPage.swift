import ShadowDesignSystem
import SwiftUI

enum TabBarDemoTab: Hashable {
  case library
  case discover
  case quests
  case profile
  case search
}

struct TabBarPage: View {
  @State private var tab = TabBarDemoTab.library

  var body: some View {
    TabView(selection: $tab) {
      Tab("Library", systemImage: "books.vertical", value: .library) {
        NavigationStack { TabBarLibraryScreen() }
      }
      Tab("Discover", systemImage: "safari", value: .discover) {
        NavigationStack { TabBarDiscoverScreen() }
      }
      Tab("Quests", systemImage: "flag", value: .quests) {
        NavigationStack { TabBarQuestsScreen() }
      }
      .badge(DemoQuest.all.filter(\.isNew).count)
      Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
        NavigationStack { TabBarProfileScreen() }
      }
      Tab(value: .search, role: .search) {
        NavigationStack { TabBarSearchScreen() }
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    #if os(iOS)
      .tabBarMinimizeBehavior(.onScrollDown)
      .tabViewBottomAccessory { ContinueReadingAccessory() }
    #endif
  }
}

private struct TabBarLibraryScreen: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        DemoCoverGrid()
        ShadowGroupedSection {
          DemoBookRows()
        } header: {
          ShadowSectionHeader("Continue reading")
        }
        ShadowGroupedSection {
          DemoBookRows(books: Array(CatalogBook.shelf.suffix(4)))
        } header: {
          ShadowSectionHeader("Recently added")
        }
        ShadowGroupedSection {
          DemoBookRows(books: CatalogBook.shelf)
        } header: {
          ShadowSectionHeader("All books")
        }
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .navigationTitle("Library")
    .shadowScreen(.root)
    .toolbar {
      CatalogDemoCloseItem()
      ToolbarItem(placement: .primaryAction) {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
          Button("Recently read") {}
          Button("Title") {}
          Button("Author") {}
        }
        .shadowBarItem()
      }
    }
  }
}

private struct TabBarDiscoverScreen: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        ShadowGroupedSection {
          DemoBookRows(books: Array(CatalogBook.shelf.prefix(4)))
        } header: {
          ShadowSectionHeader("New this week")
        }
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ShadowSectionHeader("Because you read Salt Kings")
          DemoCoverGrid(books: Array(CatalogBook.shelf.suffix(6)))
        }
      }
      .padding(DemoLayout.margin)
    }
    .navigationTitle("Discover")
    .shadowScreen(.root)
    .toolbar { CatalogDemoCloseItem() }
  }
}

private struct TabBarQuestsScreen: View {
  var body: some View {
    List {
      Section {
        ForEach(DemoQuest.all.filter(\.isNew)) { quest in QuestRow(quest: quest) }
      } header: {
        ShadowSectionHeader("New")
      }
      Section {
        ForEach(DemoQuest.all.filter { !$0.isNew }) { quest in QuestRow(quest: quest) }
      } header: {
        ShadowSectionHeader("In progress")
      }
    }
    .shadowListStyle()
    .navigationTitle("Quests")
    .shadowScreen(.root)
    .toolbar { CatalogDemoCloseItem() }
  }
}

private struct QuestRow: View {
  let quest: DemoQuest

  var body: some View {
    ShadowListRow(title: Text(verbatim: quest.title), subtitle: Text(verbatim: quest.detail), accessory: .chevron) {
      ShadowSymbolTile(systemImage: quest.progress >= 1 ? "checkmark.seal" : "flag", tint: quest.progress >= 1 ? .neutral : .accent)
    }
  }
}

private struct TabBarProfileScreen: View {
  var body: some View {
    List {
      Section {
        HStack(spacing: Spacing.space4) {
          ShadowAvatar(name: "Mira Vale", size: .large)
          VStack(alignment: .leading, spacing: Spacing.space05) {
            Text(verbatim: "Mira Vale").shadowFont(.title3)
            Text("Reading since 2024 · 12-day streak").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
          }
        }
        .padding(.vertical, Spacing.space2)
      }
      Section {
        ShadowListRow("Notifications", value: "On", accessory: .chevron) { ShadowSymbolTile(systemImage: "bell") }
        ShadowListRow("Appearance", value: "System", accessory: .chevron) { ShadowSymbolTile(systemImage: "moon") }
        ShadowListRow("Downloads", value: "3 books", accessory: .chevron) { ShadowSymbolTile(systemImage: "arrow.down.circle") }
      } header: {
        ShadowSectionHeader("Settings")
      }
    }
    .shadowListStyle()
    .navigationTitle("Profile")
    .shadowScreen(.root)
    .toolbar { CatalogDemoCloseItem() }
  }
}

private struct TabBarSearchScreen: View {
  @State private var query = ""

  private var results: [CatalogBook] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return CatalogBook.shelf }
    return CatalogBook.shelf.filter { $0.title.localizedStandardContains(trimmed) }
  }

  var body: some View {
    List {
      if results.isEmpty {
        ShadowContentUnavailable("No results", message: "Try a title, an author or a tag.")
          .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(results) { book in
            ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress)) { ListCover(book: book) }
          }
        } header: {
          ShadowSectionHeader(query.isEmpty ? "Your library" : "Results")
        }
      }
    }
    .shadowListStyle()
    .navigationTitle("Search")
    .shadowScreen(.root)
    .searchable(text: $query, prompt: "Titles, authors, tags")
    .toolbar { CatalogDemoCloseItem() }
  }
}

import ShadowDesignSystem
import SwiftUI

enum StoryBiblePage: String, CaseIterable, Hashable, Identifiable {
  case characters = "Characters"
  case places = "Places"
  case factions = "Factions"
  case timeline = "Timeline"
  case glossary = "Glossary"

  var id: Self { self }

  var systemImage: String {
    switch self {
    case .characters: "person.2"
    case .places: "map"
    case .factions: "flag.2.crossed"
    case .timeline: "calendar"
    case .glossary: "character.book.closed"
    }
  }
}

struct ToolbarPage: View {
  @State private var path: [StoryBiblePage] = [.characters]

  var body: some View {
    NavigationStack(path: $path) {
      List(StoryBiblePage.allCases) { page in
        NavigationLink(value: page) {
          ShadowListRow(LocalizedStringKey(page.rawValue)) { ShadowSymbolTile(systemImage: page.systemImage) }
        }
      }
      .shadowListStyle()
      .navigationTitle("Story Bible")
      .shadowScreen(.root)
      .toolbar { CatalogDemoCloseItem() }
      .navigationDestination(for: StoryBiblePage.self) { page in
        StoryBibleEditor(page: page)
      }
    }
  }
}

private struct StoryBibleEditor: View {
  let page: StoryBiblePage
  @State private var isBold = false
  @State private var isItalic = false
  @State private var isBookmarked = true
  @State private var query = ""
  @State private var pageNumber = 3

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  var body: some View {
    ScrollView {
      DemoReader(bold: isBold, italic: isItalic)
    }
    .catalogScrollAnchor()
    .navigationTitle(LocalizedStringKey(page.rawValue))
    .demoSubtitle("Story Bible")
    .shadowScreen(.pushed)
    .demoEditorRoleWhenRegular()
    #if os(macOS)
      .toolbar(id: "story-bible") { macToolbar }
      .searchable(text: $query, placement: .toolbar, prompt: "Search")
    #elseif os(iOS)
      .toolbar {
        if horizontalSizeClass == .compact {
          compactToolbar
        } else {
          regularToolbar
        }
      }
    #else
      .toolbar { regularToolbar }
    #endif
  }

  private var boldToggle: some View {
    Toggle("Bold", systemImage: "bold", isOn: $isBold)
      .keyboardShortcut("b")
      .help("Bold")
      .shadowBarItem()
  }

  private var italicToggle: some View {
    Toggle("Italic", systemImage: "italic", isOn: $isItalic)
      .keyboardShortcut("i")
      .help("Italic")
      .shadowBarItem()
  }

  private var doneButton: some View {
    Button("Done") {}
      .shadowToolbarProminent()
  }

  @ToolbarContentBuilder
  private var regularToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      boldToggle
      italicToggle
    }
    #if !os(visionOS)
      ToolbarSpacer(.fixed, placement: .primaryAction)
    #endif
    ToolbarItem(placement: .confirmationAction) { doneButton }
  }

  #if os(iOS)
    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
      ToolbarItem(placement: .confirmationAction) { doneButton }
      ToolbarItemGroup(placement: .bottomBar) {
        Group {
          Button("Previous page", systemImage: "chevron.backward") { pageNumber -= 1 }
          Button("Next page", systemImage: "chevron.forward") { pageNumber += 1 }
        }
        .shadowBarItem()
      }
      ToolbarSpacer(.flexible, placement: .bottomBar)
      ToolbarItemGroup(placement: .bottomBar) {
        Group {
          Menu("Format", systemImage: "textformat") {
            boldToggle
            italicToggle
          }
          Toggle("Bookmark", systemImage: "bookmark", isOn: $isBookmarked)
          ShareLink(item: "Characters")
        }
        .shadowBarItem()
      }
    }
  #endif

  #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some CustomizableToolbarContent {
      ToolbarItem(id: "bold", placement: .primaryAction) { boldToggle }
      ToolbarItem(id: "italic", placement: .primaryAction) { italicToggle }
      ToolbarItem(id: "bookmark", placement: .primaryAction) {
        Toggle("Bookmark", systemImage: "bookmark", isOn: $isBookmarked).help("Bookmark").shadowBarItem()
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(id: "share", placement: .primaryAction) {
        ShareLink(item: "Characters").help("Share").shadowBarItem()
      }
      ToolbarItem(id: "more", placement: .primaryAction) {
        Menu("More", systemImage: "ellipsis") {
          Button("Duplicate page") {}
          Button("Export as Markdown…") {}
        }
        .help("More")
        .shadowBarItem()
      }
    }
  #endif
}

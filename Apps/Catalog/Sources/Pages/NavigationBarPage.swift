import ShadowDesignSystem
import SwiftUI

enum NavigationBarDemoRoute: Hashable {
  case book(CatalogBook)
  case chapter(DemoChapter)
}

struct NavigationBarPage: View {
  @State private var path: [NavigationBarDemoRoute] = DemoPlatform.opensDetail ? [.book(CatalogBook.shelf[0]), .chapter(.featured)] : []

  var body: some View {
    NavigationStack(path: $path) {
      NavigationBarLibraryScreen()
        .navigationDestination(for: NavigationBarDemoRoute.self) { route in
          switch route {
          case .book(let book): NavigationBarBookScreen(book: book)
          case .chapter(let chapter): NavigationBarChapterScreen(chapter: chapter, path: $path)
          }
        }
    }
  }
}

private struct NavigationBarLibraryScreen: View {
  @State private var query = ""
  @State private var showsFinished = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: Spacing.space2)], spacing: Spacing.space2) {
          ForEach(CatalogBook.shelf.prefix(6)) { book in
            NavigationLink(value: NavigationBarDemoRoute.book(book)) {
              CoverArt(book: book).aspectRatio(0.75, contentMode: .fit)
            }
            .buttonStyle(.plain)
          }
        }
        ShadowGroupedSection {
          ForEach(CatalogBook.shelf.prefix(4)) { book in
            NavigationLink(value: NavigationBarDemoRoute.book(book)) {
              ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) { ListCover(book: book) }
            }
            .buttonStyle(.shadowRow)
          }
        } header: {
          ShadowSectionHeader("Continue reading")
        }
        ShadowGroupedSection {
          ForEach(CatalogBook.shelf.suffix(4)) { book in
            NavigationLink(value: NavigationBarDemoRoute.book(book)) {
              ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) { ListCover(book: book) }
            }
            .buttonStyle(.shadowRow)
          }
        } header: {
          ShadowSectionHeader("Recently added")
        }
      }
      .frame(maxWidth: ShadowMetrics.readableWidth)
      .padding(DemoLayout.margin)
      .frame(maxWidth: .infinity)
    }
    .catalogScrollAnchor()
    .navigationTitle("Library")
    .shadowScreen(.root)
    .demoSearchable(text: $query, prompt: "Titles, authors, tags")
    .toolbar {
      CatalogDemoCloseItem()
      ToolbarItemGroup(placement: .primaryAction) {
        Menu("Filter", systemImage: "line.3.horizontal.decrease") {
          Toggle("Show finished books", isOn: $showsFinished)
        }
        .shadowBarItem()
        Menu("More", systemImage: "ellipsis") {
          Button("Add book", systemImage: "plus") {}
          Button("Import EPUB…", systemImage: "square.and.arrow.down") {}
        }
        .shadowBarItem()
      }
    }
  }
}

private struct NavigationBarBookScreen: View {
  let book: CatalogBook

  var body: some View {
    List {
      Section {
        HStack(spacing: Spacing.space4) {
          CoverArt(book: book, showsTitle: false)
            .frame(width: 72, height: 96)
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: book.title).shadowFont(.title3)
            Text(verbatim: book.progress).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
          }
        }
        .padding(.vertical, Spacing.space2)
      }
      Section {
        ForEach(DemoChapter.all) { chapter in
          NavigationLink(value: NavigationBarDemoRoute.chapter(chapter)) {
            ShadowListRow(title: Text(verbatim: chapter.heading), subtitle: Text(verbatim: chapter.title), value: Text(verbatim: chapter.status.rawValue))
          }
        }
      } header: {
        ShadowSectionHeader("Chapters")
      }
    }
    .shadowListStyle()
    .navigationTitle(book.title)
    .demoSubtitle("Library")
    .shadowScreen(.pushed)
  }
}

private struct NavigationBarChapterScreen: View {
  let chapter: DemoChapter
  @Binding var path: [NavigationBarDemoRoute]
  @State private var textSize = 1

  var body: some View {
    ScrollView {
      DemoReader()
    }
    .catalogScrollAnchor()
    .navigationTitle(chapter.heading)
    .demoSubtitle("Library › The Ninth Archive")
    .shadowScreen(.pushed)
    .demoEditorRoleWhenRegular()
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu("Reading options", systemImage: "textformat.size") {
          Picker("Text size", selection: $textSize) {
            Text("Small").tag(0)
            Text("Default").tag(1)
            Text("Large").tag(2)
          }
        }
        .shadowBarItem()
        ShareLink(item: chapter.heading)
          .shadowBarItem()
      }
      #if !os(visionOS)
        ToolbarSpacer(.fixed, placement: .primaryAction)
      #endif
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { path.removeLast() }
          .shadowToolbarProminent()
      }
    }
  }
}

extension View {
  func demoSubtitle(_ subtitle: LocalizedStringKey) -> some View {
    demoSubtitle(Text(subtitle))
  }

  func demoSubtitle(verbatim subtitle: String) -> some View {
    demoSubtitle(Text(verbatim: subtitle))
  }

  func demoSubtitle(_ subtitle: Text) -> some View {
    #if os(visionOS)
      self
    #else
      navigationSubtitle(subtitle)
    #endif
  }

  func demoEditorRoleWhenRegular() -> some View {
    modifier(DemoEditorRole())
  }

  func demoSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
    #if os(iOS)
      searchable(text: text, placement: .navigationBarDrawer, prompt: prompt)
    #else
      searchable(text: text, prompt: prompt)
    #endif
  }
}

private struct DemoEditorRole: ViewModifier {
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
      content.toolbarRole(horizontalSizeClass == .regular ? .editor : .automatic)
    #else
      content.toolbarRole(.editor)
    #endif
  }
}

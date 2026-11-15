import ShadowDesignSystem
import SwiftUI

enum SplitViewDemoLayout: String, CaseIterable, Identifiable {
  case twoColumns = "Two columns"
  case threeColumns = "Three columns"

  var id: Self { self }
}

struct SplitViewPage: View {
  @State private var layout = SplitViewDemoLayout.threeColumns
  @State private var book: CatalogBook.ID? = DemoPlatform.opensDetail ? CatalogBook.shelf[0].id : nil
  @State private var chapter: DemoChapter.ID? = DemoPlatform.opensDetail ? DemoChapter.featured.id : nil
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @State private var visibility = NavigationSplitViewVisibility.all
  @State private var showsInspector = DemoPlatform.opensDetail && ShadowDensity.current == .compact

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var selectedChapter: DemoChapter? { DemoChapter.all.first { $0.id == chapter } }

  private var presentsAsSheet: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    Group {
      switch layout {
      case .threeColumns:
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
          novels
        } content: {
          chapters
        } detail: {
          detail
        }
      case .twoColumns:
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
          chapters
            .toolbar { CatalogDemoCloseItem() }
        } detail: {
          detail
        }
      }
    }
  }

  private var novels: some View {
    List(CatalogBook.shelf, selection: $book) { book in
      ShadowSidebarLabel(Text(verbatim: book.title), systemImage: book.symbol)
    }
    .shadowListStyle(.sidebar)
    .navigationTitle("Novels")
    .shadowColumnWidth(.sidebar)
    .toolbar { CatalogDemoCloseItem() }
  }

  private var chapters: some View {
    List(DemoChapter.recent, selection: $chapter) { chapter in
      ShadowListRow(
        title: Text(verbatim: chapter.heading), subtitle: Text(verbatim: chapter.title), value: Text(verbatim: chapter.status.rawValue),
        isSelected: chapter.id == self.chapter)
    }
    .shadowListStyle(.plain)
    .catalogSnapshotFocus()
    .navigationTitle("Chapters")
    .demoSubtitle(verbatim: CatalogBook.shelf.first { $0.id == book }?.title ?? "")
    .shadowScreen(.root)
    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
  }

  private var detail: some View {
    Group {
      if selectedChapter == nil {
        ShadowContentUnavailable("No chapter selected", message: "Select a chapter to start reading.")
      } else {
        ScrollView {
          DemoReader()
        }
        .catalogScrollAnchor()
      }
    }
    .navigationTitle(Text(verbatim: selectedChapter?.heading ?? ""))
    .demoSubtitle(verbatim: selectedChapter?.title ?? "")
    .shadowScreen(.pushed)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu("Layout", systemImage: "rectangle.split.3x1") {
          Picker("Layout", selection: $layout) {
            ForEach(SplitViewDemoLayout.allCases) { option in Text(LocalizedStringKey(option.rawValue)).tag(option) }
          }
        }
        .shadowBarItem()
      }
      ToolbarItem(placement: .primaryAction) {
        InspectorToggle(isPresented: $showsInspector)
      }
    }
    .demoInspector(isPresented: $showsInspector) {
      DemoChapterInspector(chapter: selectedChapter, presentsAsSheet: presentsAsSheet, isPresented: $showsInspector)
        .shadowColumnWidth(.inspector)
        .presentationDetents([.medium, .large])
    }
  }
}

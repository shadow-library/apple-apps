import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct NovelForgeShell: View {
  @State private var library: LibraryModel
  @State private var navigators = NovelNavigators()
  @State private var readers = NovelReaders()
  @Environment(LibraryWelcomeModel.self) private var welcome
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(store: VaultStore, ageGate: AgeGate) {
    _library = State(initialValue: LibraryModel(store: store, ageGate: ageGate))
  }

  var body: some View {
    @Bindable var library = library
    layout
      .environment(library)
      .focusedSceneValue(\.newNovel, library.presenting == nil ? { library.present(.create) } : nil)
      .onChange(of: NovelLayout(sizeClass: sizeClass), initial: true) { _, layout in navigators.layout = layout }
      .task(id: library.generation) { await library.observe() }
      .onChange(of: library.state) {
        library.reconcileSelection()
        if library.state.value != nil {
          let keeping = library.knownNovels.union(library.selection.map { [$0] } ?? [])
          navigators.prune(keeping: keeping)
          readers.prune(keeping: keeping)
        }
      }
      .sheet(item: $library.presenting) { sheet in sheetContent(sheet) }
      .alert(
        Text("Something went wrong", tableName: "Navigation"), isPresented: Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } }),
        presenting: library.failure
      ) { _ in
        Button {
          library.failure = nil
        } label: {
          Text("OK", tableName: "Navigation")
        }
      } message: { failure in
        failure.error.text
      }
  }

  @ViewBuilder
  private var layout: some View {
    switch NovelLayout(sizeClass: sizeClass) {
    case .regular:
      NavigationSplitView {
        LibrarySidebar(library: library)
      } content: {
        sections
      } detail: {
        detail
      }
    case .compact:
      CompactShell(library: library, navigators: navigators, readers: readers)
    }
  }

  @ViewBuilder
  private var sections: some View {
    if let novel = library.selection {
      NovelSectionList(navigator: navigators.navigator(for: novel))
    } else if let list = library.state.value, welcome.shows(list) {
      Color.clear.fillingSurface()
    } else {
      ShadowContentUnavailable(Text("Choose a novel", tableName: "Navigation"), systemImage: "book.closed")
        .fillingSurface()
    }
  }

  @ViewBuilder
  private var detail: some View {
    if library.selection == nil, let list = library.state.value, welcome.shows(list) {
      LibraryWelcome(welcome: welcome, library: library).fillingSurface()
    } else if let novel = library.selection, let section = navigators.navigator(for: novel).section {
      NovelDetailView(navigator: navigators.navigator(for: novel), readers: readers, section: section, context: library.context(for: novel))
        .id(novel)
    } else {
      ShadowContentUnavailable(
        Text("Nothing selected", tableName: "Navigation"), systemImage: "sidebar.left", message: Text("Choose a novel and a section to see it here.", tableName: "Navigation")
      )
      .fillingSurface()
    }
  }

  @ViewBuilder
  private func sheetContent(_ sheet: NovelSheet) -> some View {
    switch sheet {
    case .create: NovelFormSheet(mode: .create, library: library)
    case .edit(let novel): NovelFormSheet(mode: .edit(novel: novel.id, title: novel.displayTitle), library: library)
    case .clone(let novel): NovelFormSheet(mode: .clone(source: novel.id, title: novel.displayTitle), library: library)
    }
  }
}

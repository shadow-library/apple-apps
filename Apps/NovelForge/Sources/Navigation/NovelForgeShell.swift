import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct NovelForgeShell: View {
  @State private var library: LibraryModel
  @State private var navigators = NovelNavigators()

  init(store: VaultStore) {
    _library = State(initialValue: LibraryModel(store: store))
  }

  var body: some View {
    @Bindable var library = library
    NavigationSplitView {
      LibrarySidebar(library: library)
    } content: {
      sections
    } detail: {
      detail
    }
    .environment(library)
    .focusedSceneValue(\.newNovel, library.presenting == nil ? { library.present(.create) } : nil)
    .task(id: library.generation) { await library.observe() }
    .onChange(of: library.state) {
      library.reconcileSelection()
      if library.state.value != nil { navigators.prune(keeping: library.knownNovels.union(library.selection.map { [$0] } ?? [])) }
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
  private var sections: some View {
    if let novel = library.selection {
      NovelSectionList(navigator: navigators.navigator(for: novel))
    } else {
      ShadowContentUnavailable(Text("Choose a novel", tableName: "Navigation"), systemImage: "book.closed")
        .fillingSurface()
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let novel = library.selection, let section = navigators.navigator(for: novel).section {
      NovelDetailView(navigator: navigators.navigator(for: novel), section: section, context: library.context(for: novel))
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

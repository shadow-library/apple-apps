import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct CompactShell: View {
  let library: LibraryModel
  let navigators: NovelNavigators
  let readers: NovelReaders
  @State private var column: NavigationSplitViewColumn

  init(library: LibraryModel, navigators: NovelNavigators, readers: NovelReaders) {
    self.library = library
    self.navigators = navigators
    self.readers = readers
    _column = State(initialValue: library.selection == nil ? .sidebar : .detail)
  }

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $column) {
      LibrarySidebar(library: library)
    } detail: {
      detail
    }
    .onChange(of: library.selection) { _, selection in column = selection == nil ? .sidebar : .detail }
    .onChange(of: column) { _, column in
      if column == .sidebar { library.selection = nil }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let novel = library.selection {
      CompactNovelView(navigator: navigators.navigator(for: novel), readers: readers, context: library.context(for: novel)).id(novel)
    } else {
      ShadowContentUnavailable(Text("Choose a novel", tableName: "Navigation"), systemImage: "book.closed").fillingSurface()
    }
  }
}

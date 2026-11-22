import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct LibrarySidebar: View {
  #if os(macOS)
    private static let syncPlacement = ToolbarItemPlacement.automatic
  #else
    private static let syncPlacement = ToolbarItemPlacement.topBarLeading
  #endif

  @Bindable var library: LibraryModel
  @Environment(LibraryWelcomeModel.self) private var welcome
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    content
      .navigationTitle(Text("Library", tableName: "Library"))
      .shadowColumnWidth(.sidebar)
      .toolbar {
        ToolbarItem(placement: Self.syncPlacement) {
          SyncStatusIndicator().shadowBarItem()
        }
        ToolbarItem {
          Button {
            library.present(.create)
          } label: {
            Label(title: { Text("New Novel", tableName: "Library") }, icon: { Image(systemName: "plus") })
          }
          .shadowBarItem()
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch library.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(
        Text("The library could not be read", tableName: "Library"), systemImage: "exclamationmark.triangle", message: error.text
      ) {
        Button {
          library.retry()
        } label: {
          Text("Try Again", tableName: "Library")
        }
      }
    case .loaded(let list):
      listView(list)
    }
  }

  private func listView(_ list: LibraryList) -> some View {
    List(selection: $library.selection) {
      Section {
        ForEach(list.novels, id: \.novel.id) { row($0) }
        if list.novels.isEmpty && !list.archived.isEmpty {
          Text("No active novels", tableName: "Library").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      } header: {
        ShadowSidebarHeader(Text("Novels", tableName: "Library"))
      }
      if !list.archived.isEmpty {
        Section {
          ForEach(list.archived, id: \.novel.id) { row($0) }
        } header: {
          ShadowSidebarHeader(Text("Archived", tableName: "Library"))
        }
      }
      if list.unreadable > 0 {
        Section {
          Label(title: { Text("\(list.unreadable) novels cannot be read by this version", tableName: "Library") }, icon: { Image(systemName: "exclamationmark.triangle") })
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.warningText)
        }
      }
    }
    .listStyle(.sidebar)
    .onChange(of: list, initial: true) { welcome.libraryChanged(list) }
    .overlay {
      if welcome.shows(list) && NovelLayout(sizeClass: sizeClass) == .compact {
        LibraryWelcome(welcome: welcome, library: library)
      } else if list.novels.isEmpty && list.archived.isEmpty {
        ShadowContentUnavailable(
          Text("No novels yet", tableName: "Library"), systemImage: "book.closed",
          message: Text("Start a novel from a title and, if you like, your notes.", tableName: "Library")
        ) {
          Button {
            library.present(.create)
          } label: {
            Text("New Novel", tableName: "Library")
          }
          if !welcome.shows(list) { TryDemoButton() }
        }
      }
    }
  }

  private func row(_ entry: LibraryEntry) -> some View {
    NovelRow(entry: entry)
      .tag(entry.novel.id)
      .contextMenu { NovelActions(library: library, novel: entry.novel, placement: .contextMenu) }
  }
}

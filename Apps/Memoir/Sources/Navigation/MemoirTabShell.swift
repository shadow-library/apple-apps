import MemoirCore
import ShadowDesignSystem
import SwiftUI

struct MemoirTabShell: View {
  let stores: MemoirStores
  @Bindable var navigator: MemoirNavigator

  var body: some View {
    TabView(selection: $navigator.tab) {
      ForEach(MemoirTab.allCases) { tab in
        Tab(value: tab) {
          NavigationStack(path: path(of: tab)) {
            root(of: tab)
              .navigationDestination(for: MemoirDestination.self) { MemoirDestinationView(destination: $0, stores: stores) }
          }
        } label: {
          Label(title: { Text(tab.title) }, icon: { Image(systemName: tab.systemImage) })
        }
      }
    }
  }

  private func path(of tab: MemoirTab) -> Binding<[MemoirDestination]> {
    Binding(get: { navigator.paths[tab] ?? [] }, set: { navigator.paths[tab] = $0 })
  }

  @ViewBuilder
  private func root(of tab: MemoirTab) -> some View {
    if let destination = tab.root {
      MemoirDestinationView(destination: destination, stores: stores)
        .toolbar {
          ForEach(tab.toolbar) { entry in
            ToolbarItem { toolbarItem(entry, in: tab).shadowBarItem() }
          }
        }
    } else {
      LogHub(destinations: tab.pushed)
    }
  }

  @ViewBuilder
  private func toolbarItem(_ entry: MemoirToolbarEntry, in tab: MemoirTab) -> some View {
    switch entry {
    case .link(let destination):
      Button {
        navigator.push(destination, in: tab)
      } label: {
        Label(title: { Text(destination.title) }, icon: { Image(systemName: destination.systemImage) })
      }
    case .menu(let section, let destinations):
      Menu {
        ForEach(destinations) { destination in
          Button {
            navigator.push(destination, in: tab)
          } label: {
            Label(title: { Text(destination.title) }, icon: { Image(systemName: destination.systemImage) })
          }
        }
      } label: {
        Label(title: { section.title.map { Text($0) } }, icon: { Image(systemName: section.systemImage) })
      }
    }
  }
}

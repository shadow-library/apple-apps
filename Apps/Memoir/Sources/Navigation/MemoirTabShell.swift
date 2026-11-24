import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// The tab bar with the tabs the modules show; a lone tab is its stack without a bar, its root's toolbar reaching everything else.
struct MemoirTabShell: View {
  #if os(macOS)
    private static let syncPlacement = ToolbarItemPlacement.automatic
  #else
    private static let syncPlacement = ToolbarItemPlacement.topBarLeading
  #endif

  let context: MemoirScreenContext
  @Bindable var navigator: MemoirNavigator

  var body: some View {
    if navigator.map.showsTabBar {
      TabView(selection: $navigator.tab) {
        ForEach(navigator.map.tabs) { tab in
          Tab(value: tab) {
            stack(of: tab)
          } label: {
            Label(title: { Text(navigator.map.title(of: tab)) }, icon: { Image(systemName: navigator.map.systemImage(of: tab)) })
          }
        }
      }
    } else {
      stack(of: navigator.tab)
    }
  }

  private func stack(of tab: MemoirTab) -> some View {
    NavigationStack(path: Binding(get: { navigator.paths[tab] ?? [] }, set: { navigator.paths[tab] = $0 })) {
      root(of: tab)
        .navigationDestination(for: MemoirRoute.self) { MemoirRouteView(route: $0, context: context) }
    }
  }

  private func root(of tab: MemoirTab) -> some View {
    Group {
      if let destination = navigator.map.root(of: tab) {
        MemoirDestinationView(destination: destination, context: context)
      } else {
        LogHub(destinations: navigator.map.listed(in: tab))
      }
    }
    .toolbar {
      ForEach(navigator.map.toolbar(of: tab)) { entry in
        ToolbarItem { toolbarItem(entry, in: tab).shadowBarItem() }
      }
    }
    .toolbar {
      ToolbarItem(placement: Self.syncPlacement) { SyncStatusIndicator().shadowBarItem() }
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

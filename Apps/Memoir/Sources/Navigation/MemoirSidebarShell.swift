import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct MemoirSidebarShell: View {
  #if os(macOS)
    private static let syncPlacement = ToolbarItemPlacement.automatic
  #else
    private static let syncPlacement = ToolbarItemPlacement.topBarLeading
  #endif

  let context: MemoirScreenContext
  let navigator: MemoirNavigator

  var body: some View {
    NavigationSplitView {
      List(selection: Binding(get: { navigator.selection }, set: { if let destination = $0 { navigator.selection = destination } })) {
        ForEach(MemoirSection.allCases) { section in
          Section {
            ForEach(section.destinations) { destination in
              ShadowSidebarLabel(Text(destination.title), systemImage: destination.systemImage).tag(destination)
            }
          } header: {
            if let title = section.title { ShadowSidebarHeader(Text(title)) }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationTitle(Text("Memoir", tableName: "Navigation"))
      .shadowColumnWidth(.sidebar)
      .toolbar {
        ToolbarItem(placement: Self.syncPlacement) { SyncStatusIndicator().shadowBarItem() }
      }
    } detail: {
      NavigationStack(path: Bindable(navigator).detailPath) {
        MemoirDestinationView(destination: navigator.selection, context: context)
          .navigationDestination(for: MemoirRoute.self) { MemoirRouteView(route: $0, context: context) }
      }
      .id(navigator.selection)
    }
  }
}

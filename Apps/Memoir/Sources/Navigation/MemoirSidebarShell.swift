import MemoirCore
import ShadowDesignSystem
import SwiftUI

struct MemoirSidebarShell: View {
  let stores: MemoirStores
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
    } detail: {
      NavigationStack {
        MemoirDestinationView(destination: navigator.selection, stores: stores)
      }
      .id(navigator.selection)
    }
  }
}

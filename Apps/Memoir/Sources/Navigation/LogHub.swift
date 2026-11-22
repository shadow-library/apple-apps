import ShadowDesignSystem
import SwiftUI

/// The Log tab's root on iPhone: every capture screen, one tap away.
struct LogHub: View {
  let destinations: [MemoirDestination]

  var body: some View {
    List {
      Section {
        ForEach(destinations) { destination in
          NavigationLink(value: destination) {
            ShadowListRow(title: Text(destination.title)) { ShadowSymbolTile(systemImage: destination.systemImage) }
          }
        }
      } footer: {
        Text("Journal, meals, weight, the manual health metrics and side quests. Each entry is meant to take under ten seconds.", tableName: "Navigation")
      }
    }
    .navigationTitle(Text("Quick log", tableName: "Navigation"))
    .shadowScreen(.root)
  }
}

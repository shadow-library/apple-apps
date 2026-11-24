import Foundation
import ShadowDesignSystem
import SwiftUI

/// The Log tab's root on iPhone: every capture screen the modules show, one tap away.
struct LogHub: View {
  let destinations: [MemoirDestination]

  var body: some View {
    List {
      Section {
        ForEach(destinations) { destination in
          NavigationLink(value: MemoirRoute.destination(destination)) {
            ShadowListRow(title: Text(destination.title)) { ShadowSymbolTile(systemImage: destination.systemImage) }
          }
        }
      } footer: {
        Text(Self.footer(listing: destinations))
      }
    }
    .navigationTitle(Text("Quick log", tableName: "Navigation"))
    .shadowScreen(.root)
  }

  /// The reference's footer names every capture screen, so it shows only while all of them are listed.
  static func footer(listing destinations: [MemoirDestination]) -> LocalizedStringResource {
    guard destinations == MemoirDestination.allCases.filter({ $0.tab == .log }) else {
      return LocalizedStringResource("Each entry is meant to take under ten seconds.", table: "Navigation")
    }
    return LocalizedStringResource("Journal, meals, weight, the manual health metrics and side quests. Each entry is meant to take under ten seconds.", table: "Navigation")
  }
}

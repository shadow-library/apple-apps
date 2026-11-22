import MemoirCore
import ShadowDesignSystem
import SwiftUI

struct SettingsView: View {
  let stores: MemoirStores

  var body: some View {
    List {
      Section {
        MemoirSettingsLinks(stores: stores)
      }
    }
    .navigationTitle(Text(MemoirDestination.settings.title))
    .shadowScreen(.root)
  }
}

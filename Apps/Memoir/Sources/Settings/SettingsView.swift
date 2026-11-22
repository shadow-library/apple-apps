import ShadowDesignSystem
import SwiftUI

struct SettingsView: View {
  let context: MemoirScreenContext

  var body: some View {
    List {
      Section {
        MemoirSettingsLinks(stores: context.stores)
      }
    }
    .navigationTitle(Text(MemoirDestination.settings.title))
    .shadowScreen(.root)
  }
}

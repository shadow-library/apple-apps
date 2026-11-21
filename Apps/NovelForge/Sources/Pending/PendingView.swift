import ShadowDesignSystem
import SwiftUI

struct PendingView: View {
  let context: NovelContext

  var body: some View {
    ShadowColor.surfaceApp
      .ignoresSafeArea()
      .navigationTitle(Text("Waiting on you", tableName: "Pending"))
  }
}

import ShadowDesignSystem
import SwiftUI

struct MemoirPlaceholder: View {
  let destination: MemoirDestination

  init(_ destination: MemoirDestination) {
    self.destination = destination
  }

  var body: some View {
    ShadowContentUnavailable(Text(destination.title), systemImage: destination.systemImage, message: Text("This screen is not available yet.", tableName: "Navigation"))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(Text(destination.title))
      .shadowScreen(.root)
  }
}

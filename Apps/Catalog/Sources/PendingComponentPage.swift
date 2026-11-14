import ShadowDesignSystem
import SwiftUI

struct PendingComponentPage: View {
  let component: CatalogComponent

  var body: some View {
    ContentUnavailableView {
      Label(component.title, systemImage: component.systemImage)
    } description: {
      Text("This component is pending. Its states will appear here once it is built.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ShadowColor.surfaceApp)
    .accessibilityIdentifier("component-\(component.id)-pending")
  }
}

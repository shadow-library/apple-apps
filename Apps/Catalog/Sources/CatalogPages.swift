import SwiftUI

extension CatalogComponent {
  @ViewBuilder
  var page: some View {
    switch self {
    default: PendingComponentPage(component: self)
    }
  }
}

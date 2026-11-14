import SwiftUI

extension CatalogComponent {
  @ViewBuilder
  var page: some View {
    switch self {
    case .glass: GlassPage()
    case .button: ButtonPage()
    case .iconButton: IconButtonPage()
    case .card: CardPage()
    default: PendingComponentPage(component: self)
    }
  }
}

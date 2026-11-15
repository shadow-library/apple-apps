import ShadowDesignSystem
import SwiftUI

struct CatalogCloseDemoAction {
  let close: () -> Void

  func callAsFunction() { close() }
}

extension EnvironmentValues {
  @Entry var catalogCloseDemo: CatalogCloseDemoAction?
  @Entry var catalogScreen: String?
}

struct CatalogDemoHost: View {
  let component: CatalogComponent
  let close: () -> Void

  var body: some View {
    component.demo
      .environment(\.catalogCloseDemo, CatalogCloseDemoAction(close: close))
      .accessibilityIdentifier("catalog-demo-\(component.id)")
  }
}

struct CatalogDemoCloseItem: ToolbarContent {
  @Environment(\.catalogCloseDemo) private var close

  var body: some ToolbarContent {
    if let close {
      ToolbarItem(placement: Self.placement) {
        Button("Close demo", systemImage: "xmark") { close() }
          .labelStyle(.iconOnly)
          .help("Back to the catalog")
          .keyboardShortcut(.cancelAction)
          .shadowBarItem()
      }
    }
  }

  static var placement: ToolbarItemPlacement {
    #if os(macOS)
      .navigation
    #else
      .topBarLeading
    #endif
  }
}

struct PendingDemo: View {
  let component: CatalogComponent

  var body: some View {
    NavigationStack {
      PendingComponentPage(component: component)
        .navigationTitle(component.title)
        .toolbar { CatalogDemoCloseItem() }
    }
  }
}

import ShadowDesignSystem
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

@main
struct CatalogApp: App {
  @State private var model: CatalogModel

  init() {
    let launch = CatalogLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
    #if canImport(UIKit)
      if launch.isAutomated { UIView.setAnimationsEnabled(false) }
    #endif
    _model = State(initialValue: CatalogModel(launch: launch))
  }

  var body: some Scene {
    WindowGroup {
      CatalogView(model: model)
        .shadowTheme()
        .preferredColorScheme(model.appearance.colorScheme)
        .transaction { transaction in
          guard model.launch.isAutomated else { return }
          transaction.animation = nil
          transaction.disablesAnimations = true
        }
        #if os(macOS)
          .frame(minWidth: 900, minHeight: 600)
        #endif
    }
    .defaultSize(width: 1280, height: 820)
  }
}

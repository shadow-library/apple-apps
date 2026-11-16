import Foundation
@_spi(Preview) import ShadowDesignSystem
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

@main
struct CatalogApp: App {
  @State private var model: CatalogModel

  init() {
    let launch = CatalogLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
    if launch.listsComponents { Self.listPagesAndExit() }
    #if canImport(UIKit)
      if launch.isAutomated { UIView.setAnimationsEnabled(false) }
    #endif
    _model = State(initialValue: CatalogModel(launch: launch))
  }

  var body: some Scene {
    WindowGroup {
      CatalogView(model: model)
        .shadowTheme()
        .environment(\.catalogScrollFraction, model.launch.scrollFraction)
        .environment(\.catalogScrollSettleDelay, model.launch.scrollSettleDelay)
        .environment(\.catalogPresentsSample, model.launch.presentsSample)
        .environment(\.catalogScreen, model.launch.screen)
        .environment(\.catalogTakesSnapshot, model.launch.snapshotURL != nil)
        .environment(\.catalogIsAutomated, model.launch.isAutomated)
        .shadowPreviewHoverEffects(model.launch.snapshotURL == nil)
        .preferredColorScheme(model.appearance.colorScheme)
        .transaction { transaction in
          guard model.launch.isAutomated else { return }
          transaction.animation = nil
          transaction.disablesAnimations = true
        }
        #if os(macOS)
          .frame(minWidth: 900, minHeight: 600)
          .catalogSnapshot(model.launch)
        #endif
    }
    .defaultSize(width: 1280, height: 820)
  }

  private static func listPagesAndExit() -> Never {
    print(CatalogPage.all.map(\.id).joined(separator: "\n"))
    exit(EXIT_SUCCESS)
  }
}

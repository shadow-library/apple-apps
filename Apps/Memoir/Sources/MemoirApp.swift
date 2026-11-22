import ShadowDesignSystem
import SwiftUI

@main
struct MemoirApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(MemoirAppDelegate.self) private var delegate
  #else
    @UIApplicationDelegateAdaptor(MemoirAppDelegate.self) private var delegate
  #endif
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      MemoirRootView(vault: delegate.vault)
        .shadowTheme()
        #if os(macOS)
          .frame(minWidth: 800, minHeight: 560)
        #endif
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await delegate.vault.refreshDay() }
    }
  }
}

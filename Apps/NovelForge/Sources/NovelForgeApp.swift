import Foundation
import ShadowDesignSystem
import ShadowStore
import SwiftUI

@main
struct NovelForgeApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(NovelForgeAppDelegate.self) private var delegate
  #endif
  @State private var vault = VaultModel(locate: Self.locate)
  @State private var ai = AIServices.live()

  var body: some Scene {
    WindowGroup {
      RootView(vault: vault)
        .environment(ai)
        .task { await ai.loadOpenRouterModelsIfKeyed() }
        .shadowTheme()
        .flushingUnsavedWork()
        #if os(macOS)
          .frame(minWidth: 900, minHeight: 600)
        #endif
    }
    .commands { NovelForgeCommands() }
    #if os(macOS)
      Settings { AISettingsScene(vault: vault, services: ai) }
    #endif
  }

  private nonisolated static func locate() throws(VaultOpenError) -> StoreLocation {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return .inMemory }
    return try VaultOpener.defaultLocation()
  }
}

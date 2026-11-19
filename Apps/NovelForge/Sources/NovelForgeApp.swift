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
  @State private var chats = ChatRuntimes()
  @State private var jobs = JobRuntimes()

  var body: some Scene {
    WindowGroup {
      RootView(vault: vault)
        .environment(ai)
        .environment(chats)
        .environment(jobs)
        .task { await ai.loadOpenRouterModelsIfKeyed() }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await chats.launch(vault.store, services: ai) }
        .task(id: vault.store.map(ObjectIdentifier.init)) { await jobs.launch(vault.store, services: ai) }
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

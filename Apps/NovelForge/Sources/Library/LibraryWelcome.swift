import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Whether this device's first run is over: the welcome was dismissed, or the library has held a novel. Kept in this device's defaults, never synced.
struct LibraryWelcomeStore {
  static let key = "com.shadow.apps.novelforge.library.welcome-done"

  let defaults: UserDefaults

  func isDone() -> Bool {
    defaults.bool(forKey: Self.key)
  }

  func markDone() {
    defaults.set(true, forKey: Self.key)
  }
}

@MainActor
@Observable
final class LibraryWelcomeModel {
  private(set) var isDone: Bool
  /// The way into the demo, once the app offers one; without it the welcome offers none.
  var tryDemo: (() -> Void)?
  @ObservationIgnored private let store: LibraryWelcomeStore

  init(store: LibraryWelcomeStore) {
    self.store = store
    isDone = store.isDone()
  }

  static func live() -> LibraryWelcomeModel {
    LibraryWelcomeModel(store: LibraryWelcomeStore(defaults: .standard))
  }

  /// A library with archived novels, or novels this version cannot read, is not empty.
  func shows(_ list: LibraryList) -> Bool {
    !isDone && Self.isEmpty(list)
  }

  func dismiss() {
    guard !isDone else { return }
    store.markDone()
    isDone = true
  }

  func libraryChanged(_ list: LibraryList) {
    guard !Self.isEmpty(list) else { return }
    dismiss()
  }

  private static func isEmpty(_ list: LibraryList) -> Bool {
    list.novels.isEmpty && list.archived.isEmpty && list.unreadable == 0
  }
}

struct LibraryWelcome: View {
  let welcome: LibraryWelcomeModel
  let library: LibraryModel
  @Environment(AIServices.self) private var services
  @State private var connecting = false
  @State private var hasProvider = true

  var body: some View {
    ShadowContentUnavailable(
      Text("Welcome to Novel Forge", tableName: "Library"), systemImage: "book.pages",
      message: Text(
        "Plan a novel chapter by chapter and write it with an AI model from a provider you connect. Your library is stored on your devices and syncs only where you choose.",
        tableName: "Library")
    ) {
      VStack(spacing: Spacing.space3) {
        Button {
          library.present(.create)
        } label: {
          Text("Start Writing", tableName: "Library")
        }
        .buttonStyle(.borderedProminent)
        if !hasProvider {
          VStack(spacing: Spacing.space1) {
            Button {
              connecting = true
            } label: {
              Text("Connect a Provider", tableName: "Library")
            }
            .accessibilityHint(Text("Anthropic recommended", tableName: "Library"))
            Text("Anthropic recommended", tableName: "Library").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).accessibilityHidden(true)
          }
        }
        if let tryDemo = welcome.tryDemo {
          Button(action: tryDemo) {
            Text("Try the Demo", tableName: "Library")
          }
        }
        Button {
          welcome.dismiss()
        } label: {
          Text("Not Now", tableName: "Library")
        }
        .buttonStyle(.borderless)
      }
    }
    .aiProviderSheet(isPresented: $connecting, services: services) {}
    .task(id: ProviderCheck(keysRevision: services.keysRevision, settings: services.settings)) { hasProvider = services.isReadyForStandardCalls }
  }
}

private struct ProviderCheck: Equatable {
  let keysRevision: Int
  let settings: AISettings
}

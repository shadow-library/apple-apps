import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowSync
import Testing

@testable import ShadowAppShell

extension AppIdentity {
  static let fixture = AppIdentity(
    id: "com.shadow.apps.shelltest", displayName: "Shell Test", vaultNoun: "library", vaultTitle: "Library", exampleBucketName: "my-notes")
}

extension ConsentDisclosure {
  static let fixtureText = ConsentDisclosure(
    id: "fixture-text/v2", dataClass: "fixture-text", title: { "Your text" }, explanation: { provider in "Your text goes to \(provider)." })
}

/// A vault store with the AI ledger and one note kind, opened as an app opens its own: with the sync kernel's kinds and migrations.
enum ShellStore {
  static let note: EntityKind = {
    guard let kind = EntityKind("app_note") else { preconditionFailure("fixture kind is valid") }
    return kind
  }()

  static let registry = SyncKernelSchema.registry(
    version: 1, adding: LedgerSchema.entities + [EntitySchema(kind: note, shape: .record(fields: ["title": .register]), syncClass: .general)])

  static func open(_ location: StoreLocation = .inMemory, wallClock: @escaping @Sendable () -> Date = { Date() }) throws -> VaultStore {
    try VaultStore.open(location, registry: registry, migrations: SyncEngine.migrations, wallClock: wallClock)
  }

  @discardableResult
  static func writeNote(_ title: String, key: String = UUID().uuidString.lowercased(), in store: VaultStore) async throws -> EntityRef {
    guard let entityKey = EntityKey(key) else { preconditionFailure("fixture key is valid") }
    let ref = EntityRef(kind: note, key: entityKey)
    try await store.write { transaction in _ = try transaction.set(ref, ["title": .string(title)]) }
    return ref
  }

  static func title(of ref: EntityRef, in store: VaultStore) async throws -> String? {
    guard case .record(let record)? = try await store.read({ try $0.state(of: ref) }), case .string(let title)? = record[field: "title"]?.value else { return nil }
    return title
  }
}

enum ShellWait {
  @MainActor
  static func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
    for _ in 0..<12_000 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }
}

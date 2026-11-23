import Foundation
import ShadowAI
import ShadowKeychain
import ShadowNetworking
import ShadowStore
import Synchronization

@testable import ShadowAppShell

final class FakeSecureStore: SecureStore {
  private let items = Mutex<[String: Data]>([:])
  private let failing = Mutex(false)

  var failsWrites: Bool {
    get { failing.withLock { $0 } }
    set { failing.withLock { $0 = newValue } }
  }

  var accounts: [String] { items.withLock { $0.keys.sorted() } }

  func data(forKey key: String) throws(SecureStoreError) -> Data? { items.withLock { $0[key] } }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    guard !failsWrites else { throw .unexpectedStatus(-34018) }
    items.withLock { $0[key] = data }
  }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    guard !failsWrites else { throw .unexpectedStatus(-34018) }
    return items.withLock { items in
      guard items[key] == nil else { return false }
      items[key] = data
      return true
    }
  }

  func removeValue(forKey key: String) throws(SecureStoreError) { items.withLock { $0[key] = nil } }

  func allKeys() throws(SecureStoreError) -> [String] { accounts }
}

struct SettingsWorld {
  let services: AIServices
  let secure: FakeSecureStore
  let defaults: UserDefaults
  let suite: String
  let store: VaultStore

  func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor
enum SettingsFixtures {
  nonisolated static let secret = "sk-test-secret-value"

  static func failing(_ error: ModelError) -> CredentialValidation {
    { (_, _) async throws(ModelError) -> CredentialStatus in throw error }
  }

  static func failingListing(_ error: ModelError) -> ModelListing {
    { () async throws(ModelError) -> [RemoteModel] in throw error }
  }

  static func world(
    validation: @escaping CredentialValidation = { _, _ in .valid(label: nil) }, listing: @escaping ModelListing = { [] },
    transport: any HTTPTransport & HTTPStreamingTransport = URLSessionTransport(), offersUnrestrictedModel: Bool = false
  ) throws -> SettingsWorld {
    let suite = "ShadowAppShellSettingsTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("A defaults suite is always available.") }
    let secure = FakeSecureStore()
    let services = AIServices(
      identity: .fixture, keys: .standard(store: secure), settingsStore: AISettingsStore(identity: .fixture, defaults: defaults), transport: transport,
      disclosures: [.fixtureText], requestGuard: { _ in nil }, offersUnrestrictedModel: offersUnrestrictedModel, validation: validation, listing: listing)
    return SettingsWorld(services: services, secure: secure, defaults: defaults, suite: suite, store: try ShellStore.open())
  }
}

final class CallCount: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock { $0 } }

  func increment() { count.withLock { $0 += 1 } }
}

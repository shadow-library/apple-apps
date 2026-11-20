import Foundation
import ShadowCore
import ShadowKeychain
import Synchronization

// Never calls `setData` or `removeValue`: on a synced store either would change or delete the item on every device.
public final class KeyRing: Sendable {
  private struct State: Sendable {
    var keys: [KeyID: VaultKey] = [:]
    var unreadable: Set<String> = []
  }

  private enum Loaded {
    case key(VaultKey)
    case unreadable(String)
  }

  private static let maximumInsertAttempts = 2

  public let vault: VaultID
  private let store: any SecureStore
  private let makeKeyID: @Sendable () -> KeyID
  private let prefix: String
  private let state = Mutex(State())

  public init(vault: VaultID, store: any SecureStore, makeKeyID: @escaping @Sendable () -> KeyID = { KeyID(UUID.v7()) }) {
    self.vault = vault
    self.store = store
    self.makeKeyID = makeKeyID
    prefix = Self.itemPrefix(vault: vault)
  }

  public static func itemName(vault: VaultID, key: KeyID) -> String {
    itemPrefix(vault: vault) + key.description
  }

  private static func itemPrefix(vault: VaultID) -> String {
    "vault-key/\(vault.rawValue)/"
  }

  public var keyIDs: [KeyID] {
    state.withLock { $0.keys.keys.sorted() }
  }

  public var unreadableItems: [String] {
    state.withLock { $0.unreadable.sorted() }
  }

  public func key(_ id: KeyID) -> VaultKey? {
    state.withLock { $0.keys[id] }
  }

  public func writingKey(floor: KeyID? = nil) -> VaultKey? {
    state.withLock { state in
      let eligible = state.keys.keys.filter { id in floor.map { id >= $0 } ?? true }
      return eligible.min().flatMap { state.keys[$0] }
    }
  }

  @discardableResult
  public func refresh() throws(KeyRingError) -> Set<KeyID> {
    let names = try Self.mapStoreError { () throws(SecureStoreError) in try store.allKeys() }
    let cached = state.withLock { Set($0.keys.keys) }
    var loaded: [Loaded] = []
    for name in names where name.hasPrefix(prefix) {
      guard let id = KeyID(String(name.dropFirst(prefix.count))) else {
        loaded.append(.unreadable(name))
        continue
      }
      if cached.contains(id) { continue }
      guard let data = try Self.mapStoreError({ () throws(SecureStoreError) in try store.data(forKey: name) }) else { continue }
      guard let key = VaultKey(id: id, rawBytes: data) else {
        loaded.append(.unreadable(name))
        continue
      }
      loaded.append(.key(key))
    }
    return state.withLock { state in
      var seen: Set<KeyID> = []
      for item in loaded {
        switch item {
        case .key(let key):
          guard state.keys[key.id] == nil else { continue }
          state.keys[key.id] = key
          seen.insert(key.id)
        case .unreadable(let name):
          state.unreadable.insert(name)
        }
      }
      return seen
    }
  }

  public func createKey() throws(KeyRingError) -> VaultKey {
    let key = VaultKey.generate(id: makeKeyID())
    try add(key)
    return key
  }

  public func add(_ key: VaultKey) throws(KeyRingError) {
    if let cached = self.key(key.id), !cached.hasSameBytes(as: key) { throw .conflictingKey(key.id) }
    try insertOrMatch(key)
    try state.withLock { state throws(KeyRingError) in
      if let cached = state.keys[key.id] {
        guard cached.hasSameBytes(as: key) else { throw .conflictingKey(key.id) }
        return
      }
      state.keys[key.id] = key
    }
  }

  private func insertOrMatch(_ key: VaultKey) throws(KeyRingError) {
    let name = Self.itemName(vault: vault, key: key.id)
    let bytes = key.rawBytes
    for _ in 0..<Self.maximumInsertAttempts {
      if try Self.mapStoreError({ () throws(SecureStoreError) in try store.insertData(bytes, forKey: name) }) { return }
      guard let existing = try Self.mapStoreError({ () throws(SecureStoreError) in try store.data(forKey: name) }) else { continue }
      guard VaultKey(id: key.id, rawBytes: existing)?.hasSameBytes(as: key) == true else { throw .conflictingKey(key.id) }
      return
    }
    throw .store("the item for key \(key.id) kept disappearing while it was written")
  }

  private static func mapStoreError<T>(_ body: () throws(SecureStoreError) -> T) throws(KeyRingError) -> T {
    do {
      return try body()
    } catch {
      if error.isInteractionNotAllowed { throw .deviceLocked }
      switch error {
      case .unexpectedStatus(let status): throw .store("\(error.code) \(status)")
      case .encoding, .decoding: throw .store(error.code)
      }
    }
  }
}

extension VaultKey {
  func hasSameBytes(as other: VaultKey) -> Bool {
    id == other.id && constantTimeEquals(rawBytes, other.rawBytes)
  }
}

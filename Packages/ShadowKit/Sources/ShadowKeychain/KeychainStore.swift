import Foundation
import Security

public struct KeychainStore: SecureStore {
  public enum DeviceAccessibility: Sendable {
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly
    case whenPasscodeSetThisDeviceOnly

    var attribute: CFString {
      switch self {
      case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
      }
    }
  }

  public enum SyncedAccessibility: Sendable {
    case whenUnlocked
    case afterFirstUnlock

    var attribute: CFString {
      switch self {
      case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
      case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
      }
    }
  }

  public enum Scope: Sendable {
    case device(DeviceAccessibility = .afterFirstUnlockThisDeviceOnly)
    case synced(SyncedAccessibility = .afterFirstUnlock)

    var isSynchronizable: Bool {
      switch self {
      case .device: false
      case .synced: true
      }
    }

    var accessibility: CFString {
      switch self {
      case .device(let accessibility): accessibility.attribute
      case .synced(let accessibility): accessibility.attribute
      }
    }
  }

  public let service: String
  public let accessGroup: String?
  public let scope: Scope

  public init(service: String, accessGroup: String? = nil, scope: Scope = .device()) {
    self.service = service
    self.accessGroup = accessGroup
    self.scope = scope
  }

  public func data(forKey key: String) throws(SecureStoreError) -> Data? {
    var query = itemQuery(forKey: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw .unexpectedStatus(status) }
    return result as? Data
  }

  public func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    let query = itemQuery(forKey: key)
    let attributes = writeAttributes(for: data)

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw .unexpectedStatus(updateStatus) }

    let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw .unexpectedStatus(addStatus) }
  }

  public func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    let status = SecItemAdd(itemQuery(forKey: key).merging(writeAttributes(for: data)) { $1 } as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw .unexpectedStatus(status) }
    return true
  }

  public func removeValue(forKey key: String) throws(SecureStoreError) {
    let status = SecItemDelete(itemQuery(forKey: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw .unexpectedStatus(status) }
  }

  public func allKeys() throws(SecureStoreError) -> [String] {
    var query = scopeQuery()
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw .unexpectedStatus(status) }
    guard let items = result as? [[String: Any]] else { throw .decoding("The keychain returned an unexpected attribute list") }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  private func writeAttributes(for data: Data) -> [String: Any] {
    [kSecValueData as String: data, kSecAttrAccessible as String: scope.accessibility]
  }

  private func itemQuery(forKey key: String) -> [String: Any] {
    var query = scopeQuery()
    query[kSecAttrAccount as String] = key
    return query
  }

  /// The data protection keychain gives macOS the same semantics as iOS; it requires the host app to be signed with a keychain entitlement.
  /// Omitting kSecAttrSynchronizable matches only device items, and kSecAttrSynchronizableAny would let one scope update or delete the other.
  private func scopeQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: scope.isSynchronizable,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}

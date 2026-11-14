import Foundation
import Security

public struct KeychainStore: SecureStore {
  public enum Accessibility: Sendable {
    case whenUnlocked
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlock
    case afterFirstUnlockThisDeviceOnly
    case whenPasscodeSetThisDeviceOnly

    var attribute: CFString {
      switch self {
      case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
      case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
      case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
      }
    }
  }

  public let service: String
  public let accessGroup: String?
  public let accessibility: Accessibility

  public init(service: String, accessGroup: String? = nil, accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly) {
    self.service = service
    self.accessGroup = accessGroup
    self.accessibility = accessibility
  }

  public func data(forKey key: String) throws(SecureStoreError) -> Data? {
    var query = baseQuery(forKey: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw .unexpectedStatus(status) }
    return result as? Data
  }

  public func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    let query = baseQuery(forKey: key)
    let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility.attribute]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw .unexpectedStatus(updateStatus) }

    let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw .unexpectedStatus(addStatus) }
  }

  public func removeValue(forKey key: String) throws(SecureStoreError) {
    let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw .unexpectedStatus(status) }
  }

  /// The data protection keychain gives macOS the same semantics as iOS; it requires the host app to be signed with a keychain entitlement.
  private func baseQuery(forKey key: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}

import Foundation
import Security
import ShadowCore

public enum SecureStoreError: ShadowError {
  case unexpectedStatus(OSStatus)
  case encoding(String)
  case decoding(String)

  public var code: String {
    switch self {
    case .unexpectedStatus: "secure_store.unexpected_status"
    case .encoding: "secure_store.encoding"
    case .decoding: "secure_store.decoding"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status): SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    case .encoding(let reason): "The value could not be encoded: \(reason)"
    case .decoding(let reason): "The stored value could not be decoded: \(reason)"
    }
  }

  /// The status for an item readable only after first unlock while the device has not been unlocked since it started.
  public var isInteractionNotAllowed: Bool {
    guard case .unexpectedStatus(let status) = self else { return false }
    return status == errSecInteractionNotAllowed
  }

  /// The data protection keychain refuses every item to a build that carries no application identifier, such as one signed without a team.
  public var isMissingEntitlement: Bool {
    guard case .unexpectedStatus(let status) = self else { return false }
    return status == errSecMissingEntitlement
  }
}

public protocol SecureStore: Sendable {
  func data(forKey key: String) throws(SecureStoreError) -> Data?
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError)
  /// Stores the value only when no item exists for the key. Returns false, and changes nothing, when one already exists.
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool
  func removeValue(forKey key: String) throws(SecureStoreError)
  func allKeys() throws(SecureStoreError) -> [String]
}

extension SecureStore {
  public func string(forKey key: String) throws(SecureStoreError) -> String? {
    guard let data = try data(forKey: key) else { return nil }
    guard let string = String(data: data, encoding: .utf8) else { throw .decoding("Stored data for \(key) is not UTF-8") }
    return string
  }

  public func setString(_ string: String, forKey key: String) throws(SecureStoreError) {
    try setData(Data(string.utf8), forKey: key)
  }

  public func insertString(_ string: String, forKey key: String) throws(SecureStoreError) -> Bool {
    try insertData(Data(string.utf8), forKey: key)
  }

  public func value<Value: Decodable>(_ type: Value.Type = Value.self, forKey key: String, decoder: JSONDecoder = JSONDecoder()) throws(SecureStoreError) -> Value? {
    guard let data = try data(forKey: key) else { return nil }
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw .decoding(String(describing: error))
    }
  }

  public func setValue<Value: Encodable>(_ value: Value, forKey key: String, encoder: JSONEncoder = JSONEncoder()) throws(SecureStoreError) {
    try setData(encode(value, with: encoder), forKey: key)
  }

  public func insertValue<Value: Encodable>(_ value: Value, forKey key: String, encoder: JSONEncoder = JSONEncoder()) throws(SecureStoreError) -> Bool {
    try insertData(encode(value, with: encoder), forKey: key)
  }

  private func encode<Value: Encodable>(_ value: Value, with encoder: JSONEncoder) throws(SecureStoreError) -> Data {
    do {
      return try encoder.encode(value)
    } catch {
      throw .encoding(String(describing: error))
    }
  }
}

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
}

public protocol SecureStore: Sendable {
  func data(forKey key: String) throws(SecureStoreError) -> Data?
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError)
  func removeValue(forKey key: String) throws(SecureStoreError)
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

  public func value<Value: Decodable>(_ type: Value.Type = Value.self, forKey key: String, decoder: JSONDecoder = JSONDecoder()) throws(SecureStoreError) -> Value? {
    guard let data = try data(forKey: key) else { return nil }
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw .decoding(String(describing: error))
    }
  }

  public func setValue<Value: Encodable>(_ value: Value, forKey key: String, encoder: JSONEncoder = JSONEncoder()) throws(SecureStoreError) {
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw .encoding(String(describing: error))
    }
    try setData(data, forKey: key)
  }
}

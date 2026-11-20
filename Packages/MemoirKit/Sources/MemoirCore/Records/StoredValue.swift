import Foundation
import ShadowCore

public protocol StoredValue: Sendable, Equatable {
  init?(stored: JSONValue)
  var stored: JSONValue { get }
}

extension String: StoredValue {
  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self = text
  }

  public var stored: JSONValue { .string(self) }
}

extension Int: StoredValue {
  public init?(stored: JSONValue) {
    guard let number = stored.intValue, let value = Int(exactly: number) else { return nil }
    self = value
  }

  public var stored: JSONValue { .int(Int64(self)) }
}

extension Int64: StoredValue {
  public init?(stored: JSONValue) {
    guard let number = stored.intValue else { return nil }
    self = number
  }

  public var stored: JSONValue { .int(self) }
}

extension Bool: StoredValue {
  public init?(stored: JSONValue) {
    guard let flag = stored.boolValue else { return nil }
    self = flag
  }

  public var stored: JSONValue { .bool(self) }
}

extension UUID: StoredValue {
  public init?(stored: JSONValue) {
    guard let text = stored.stringValue, let id = UUID(uuidString: text), id.lowercasedString.utf8.elementsEqual(text.utf8) else { return nil }
    self = id
  }

  public var stored: JSONValue { .string(lowercasedString) }
}

extension LocalDate: StoredValue {
  public init?(stored: JSONValue) {
    guard let text = stored.stringValue, let date = LocalDate(isoString: text) else { return nil }
    self = date
  }

  public var stored: JSONValue { .string(isoString) }
}

extension Array: StoredValue where Element: StoredValue {
  public init?(stored: JSONValue) {
    guard let elements = stored.arrayValue else { return nil }
    let values = elements.compactMap(Element.init(stored:))
    guard values.count == elements.count else { return nil }
    self = values
  }

  public var stored: JSONValue { .array(map(\.stored)) }
}

public enum StoredChoice<Value: RawRepresentable & CaseIterable & Hashable & Sendable>: Hashable, Sendable, StoredValue where Value.RawValue == String {
  case known(Value)
  case unknown(String)

  public init(rawValue: String) {
    guard let match = Value.allCases.first(where: { $0.rawValue.utf8.elementsEqual(rawValue.utf8) }) else {
      self = .unknown(rawValue)
      return
    }
    self = .known(match)
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(rawValue: text)
  }

  public var rawValue: String {
    switch self {
    case .known(let value): value.rawValue
    case .unknown(let text): text
    }
  }

  public var known: Value? {
    guard case .known(let value) = self else { return nil }
    return value
  }

  public var stored: JSONValue { .string(rawValue) }
}

/// A decimal number in its one canonical spelling: no sign on zero, no leading zeros, no trailing fractional zeros, no exponent.
public struct DecimalText: Hashable, Sendable, StoredValue, CustomStringConvertible {
  public static let maximumLength = 40

  public let text: String

  public init?(_ text: String) {
    guard Self.isCanonical(Array(text.utf8)) else { return nil }
    self.text = text
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(text)
  }

  public var stored: JSONValue { .string(text) }

  public var description: String { text }

  private static func isCanonical(_ bytes: [UInt8]) -> Bool {
    guard (1...maximumLength).contains(bytes.count) else { return false }
    let unsigned = bytes.first == UInt8(ascii: "-") ? Array(bytes.dropFirst()) : bytes
    let parts = unsigned.split(separator: UInt8(ascii: "."), maxSplits: 1, omittingEmptySubsequences: false)
    let whole = parts[0]
    guard !whole.isEmpty, whole.allSatisfy(isDigit), whole.count == 1 || whole.first != UInt8(ascii: "0") else { return false }
    if parts.count == 2 {
      let fraction = parts[1]
      guard !fraction.isEmpty, fraction.allSatisfy(isDigit), fraction.last != UInt8(ascii: "0") else { return false }
    }
    let isZero = parts.count == 1 && whole.elementsEqual([UInt8(ascii: "0")])
    return !(isZero && unsigned.count != bytes.count)
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}

/// Three upper-case ASCII letters; whether the code is assigned is not checked here.
public struct CurrencyCode: Hashable, Sendable, StoredValue, CustomStringConvertible {
  public let code: String

  public init?(_ code: String) {
    let bytes = Array(code.utf8)
    guard bytes.count == 3, bytes.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }) else { return nil }
    self.code = code
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(text)
  }

  public var stored: JSONValue { .string(code) }

  public var description: String { code }
}

public struct CategoryKey: Hashable, Sendable, StoredValue, CustomStringConvertible {
  public static let maximumLength = 32

  public let key: String

  public init?(_ key: String) {
    let bytes = Array(key.utf8)
    guard (1...Self.maximumLength).contains(bytes.count) else { return nil }
    guard bytes.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "_") })
    else { return nil }
    self.key = key
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(text)
  }

  public var stored: JSONValue { .string(key) }

  public var description: String { key }
}

public struct BlobName: Hashable, Sendable, StoredValue, CustomStringConvertible {
  public static let length = 64

  public let name: String

  public init?(_ name: String) {
    let bytes = Array(name.utf8)
    guard bytes.count == Self.length, bytes.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) })
    else { return nil }
    self.name = name
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(text)
  }

  public var stored: JSONValue { .string(name) }

  public var description: String { name }
}

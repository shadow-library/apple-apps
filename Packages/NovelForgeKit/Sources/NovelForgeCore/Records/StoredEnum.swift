import ShadowCore

public enum StoredEnum<Value: RawRepresentable & CaseIterable & Hashable & Sendable>: Hashable, Sendable, JSONRepresentable where Value.RawValue == String {
  case known(Value)
  case unknown(String)

  public init(rawValue: String) {
    guard let match = Value.allCases.first(where: { $0.rawValue.utf8.elementsEqual(rawValue.utf8) }) else {
      self = .unknown(rawValue)
      return
    }
    self = .known(match)
  }

  public init?(json: JSONValue) {
    guard let text = json.stringValue else { return nil }
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

  public var json: JSONValue { .string(rawValue) }
}

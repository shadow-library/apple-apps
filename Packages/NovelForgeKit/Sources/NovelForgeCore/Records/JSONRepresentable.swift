import ShadowCore

public protocol JSONReadable: Sendable {
  init?(json: JSONValue)
}

public protocol JSONWritable: Sendable {
  var json: JSONValue { get }
}

public typealias JSONRepresentable = JSONReadable & JSONWritable

extension String: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let text = json.stringValue else { return nil }
    self = text
  }

  public var json: JSONValue { .string(self) }
}

extension Int: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let number = json.intValue, let value = Int(exactly: number) else { return nil }
    self = value
  }

  public var json: JSONValue { .int(Int64(self)) }
}

extension Bool: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let flag = json.boolValue else { return nil }
    self = flag
  }

  public var json: JSONValue { .bool(self) }
}

extension Array: JSONReadable where Element: JSONReadable {
  public init?(json: JSONValue) {
    guard let elements = json.arrayValue else { return nil }
    let values = elements.compactMap { Element(json: $0) }
    guard values.count == elements.count else { return nil }
    self = values
  }
}

extension Array: JSONWritable where Element: JSONWritable {
  public var json: JSONValue { .array(map(\.json)) }
}

extension Optional: JSONWritable where Wrapped: JSONWritable {
  public var json: JSONValue {
    guard let value = self else { return .null }
    return value.json
  }
}

extension JSONValue: JSONRepresentable {
  public init?(json: JSONValue) { self = json }

  public var json: JSONValue { self }
}

extension Dictionary: JSONReadable where Key == String, Value: JSONReadable {
  public init?(json: JSONValue) {
    guard let members = json.objectValue else { return nil }
    let values = members.compactMapValues { Value(json: $0) }
    guard values.count == members.count else { return nil }
    self = values
  }
}

extension Dictionary: JSONWritable where Key == String, Value: JSONWritable {
  public var json: JSONValue { .object(mapValues(\.json)) }
}

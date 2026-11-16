import ShadowCore
import ShadowStore

public protocol FieldName: RawRepresentable, CaseIterable where RawValue == String {}

public enum FieldChange<Value: JSONWritable & Equatable>: Sendable, Equatable {
  case keep
  case set(Value)
}

public struct RecordFields<Field: FieldName>: Sendable, Equatable {
  public private(set) var members: [String: JSONValue] = [:]

  public init() {}

  public mutating func put(_ field: Field, _ value: some JSONWritable) {
    members[field.rawValue] = value.json
  }

  public mutating func put<Value: JSONWritable & Equatable>(_ field: Field, _ change: FieldChange<Value>) {
    guard case .set(let value) = change else { return }
    put(field, value)
  }

  var json: JSONValue { .object(members) }
}

public struct FieldReader<Field: FieldName>: Sendable {
  private let values: [ExactString: JSONValue]

  init(_ fields: [ExactString: FieldState]) {
    values = fields.mapValues(\.value)
  }

  init?(object json: JSONValue) {
    guard let members = json.objectValue else { return nil }
    values = Dictionary(members.map { (ExactString($0.key), $0.value) }) { first, _ in first }
  }

  public func required<Value: JSONReadable>(_ field: Field) throws(UnreadableReason) -> Value {
    guard let json = values[ExactString(field.rawValue)] else { throw .missing(field: field.rawValue) }
    guard let value = Value(json: json) else { throw .invalid(field: field.rawValue) }
    return value
  }

  public func optional<Value: JSONReadable>(_ field: Field) throws(UnreadableReason) -> Value? {
    guard let json = values[ExactString(field.rawValue)], !json.isNull else { return nil }
    guard let value = Value(json: json) else { throw .invalid(field: field.rawValue) }
    return value
  }

  func common<Value: JSONReadable>(_ field: CommonField) throws(UnreadableReason) -> Value {
    guard let json = values[ExactString(field.rawValue)] else { throw .missing(field: field.rawValue) }
    guard let value = Value(json: json) else { throw .invalid(field: field.rawValue) }
    return value
  }

  func stored(_ field: CommonField) -> JSONValue? {
    values[ExactString(field.rawValue)]
  }
}

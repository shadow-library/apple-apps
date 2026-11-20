import ShadowCore
import ShadowStore

/// A member set to `nil` is left out, so an absent first-writer field can still be filled later.
public struct RecordMembers<Field: MemoirField>: Sendable, Equatable {
  public private(set) var values: [String: JSONValue] = [:]

  public init() {}

  public mutating func put(_ field: Field, _ value: (some StoredValue)?) {
    values[field.rawValue] = value?.stored
  }

  public var json: JSONValue { .object(values) }
}

public struct MemberReader<Field: MemoirField>: Sendable {
  private let values: [ExactString: JSONValue]
  let body: JSONValue?

  init(_ values: [ExactString: JSONValue], body: JSONValue? = nil) {
    self.values = values
    self.body = body
  }

  init?(object json: JSONValue) {
    guard let members = json.objectValue else { return nil }
    self.init(Dictionary(members.map { (ExactString($0.key), $0.value) }) { first, _ in first })
  }

  public func required<Value: StoredValue>(_ field: Field) throws(MemoirUnreadable) -> Value {
    guard let json = values[ExactString(field.rawValue)] else { throw .missing(field: field.rawValue) }
    guard let value = Value(stored: json) else { throw .invalid(field: field.rawValue) }
    return value
  }

  public func optional<Value: StoredValue>(_ field: Field) throws(MemoirUnreadable) -> Value? {
    guard let json = values[ExactString(field.rawValue)], !json.isNull else { return nil }
    guard let value = Value(stored: json) else { throw .invalid(field: field.rawValue) }
    return value
  }

  func common(_ field: CommonField) -> JSONValue? {
    values[ExactString(field.rawValue)]
  }

  func requireOnlyDeclaredMembers() throws(MemoirUnreadable) {
    let known = Set(Field.allCases.map { ExactString($0.rawValue) })
    if let stray = values.keys.sorted().first(where: { !known.contains($0) }) { throw .unexpected(field: stray.value) }
  }

  static func nested<Value>(_ json: JSONValue, _ read: (MemberReader<Field>) throws(MemoirUnreadable) -> Value) -> Value? {
    guard let reader = MemberReader(object: json) else { return nil }
    do throws(MemoirUnreadable) {
      try reader.requireOnlyDeclaredMembers()
      return try read(reader)
    } catch {
      return nil
    }
  }
}

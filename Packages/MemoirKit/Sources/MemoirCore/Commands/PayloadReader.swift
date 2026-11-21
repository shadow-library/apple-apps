import Foundation
import ShadowCore

/// Reads a payload object field by field with the reference's checks (`quest-command.types.ts` and the handlers' `require*` helpers), naming each
/// field as the reference's `ValidationError` does. Every key must be read: `finish()` refuses the rest, which the reference would ignore.
struct PayloadReader {
  private let members: [String: JSONValue]
  private let prefix: String
  private var consumed: Set<String> = []

  init(_ members: [String: JSONValue], prefix: String = "") {
    self.members = members
    self.prefix = prefix
  }

  func field(_ key: String) -> String { prefix + key }

  func contains(_ key: String) -> Bool { members[key] != nil }

  mutating func value(_ key: String) -> JSONValue? {
    consumed.insert(key)
    return members[key]
  }

  /// Absent and `null` both read as `nil`, as the reference's `value === undefined || value === null`.
  mutating func present(_ key: String) -> JSONValue? {
    guard let value = value(key), !value.isNull else { return nil }
    return value
  }

  mutating func string(_ key: String) throws(CommandRefusal) -> String {
    guard let value = value(key) else { throw .invalidField(field: field(key), problem: .required) }
    guard let text = value.stringValue else { throw .invalidField(field: field(key), problem: .notString) }
    guard !text.isEmpty else { throw .invalidField(field: field(key), problem: .required) }
    return text
  }

  mutating func uuid(_ key: String) throws(CommandRefusal) -> UUID {
    let text = try string(key)
    guard let id = UUID(stored: .string(text)) else { throw .invalidField(field: field(key), problem: .notIdentifier) }
    return id
  }

  mutating func optionalUUID(_ key: String) throws(CommandRefusal) -> UUID? {
    guard contains(key) else { return nil }
    return try uuid(key)
  }

  mutating func date(_ key: String) throws(CommandRefusal) -> LocalDate {
    try Self.date(try string(key), field: field(key))
  }

  static func date(_ text: String, field: String) throws(CommandRefusal) -> LocalDate {
    guard let date = LocalDate(isoString: text) else { throw .invalidField(field: field, problem: .notDate) }
    return date
  }

  mutating func choice<Value: RuleKey>(_ key: String, as type: Value.Type = Value.self) throws(CommandRefusal) -> Value {
    guard let value = value(key) else { throw .invalidField(field: field(key), problem: .notAllowed) }
    return try Self.choice(value, field: field(key))
  }

  /// Absent or `null` is `nil`; anything else must be one of the values.
  mutating func optionalChoice<Value: RuleKey>(_ key: String, as type: Value.Type = Value.self) throws(CommandRefusal) -> Value? {
    guard let value = present(key) else { return nil }
    return try Self.choice(value, field: field(key))
  }

  static func choice<Value: RuleKey>(_ value: JSONValue, field: String) throws(CommandRefusal) -> Value {
    guard let text = value.stringValue, let match = Value.allCases.first(where: { $0.rawValue.utf8.elementsEqual(text.utf8) }) else {
      throw .invalidField(field: field, problem: .notAllowed)
    }
    return match
  }

  /// Absent is the default; a present value must be a boolean, where some reference handlers read anything but `true` as `false`.
  mutating func bool(_ key: String, default fallback: Bool) throws(CommandRefusal) -> Bool {
    guard let value = value(key) else { return fallback }
    guard let flag = value.boolValue else { throw .invalidField(field: field(key), problem: .notBoolean) }
    return flag
  }

  mutating func integer(_ key: String) throws(CommandRefusal) -> Int {
    guard let value = value(key) else { throw .invalidField(field: field(key), problem: .notInteger) }
    return try Self.integer(value, field: field(key))
  }

  static func integer(_ value: JSONValue, field: String) throws(CommandRefusal) -> Int {
    guard let number = value.intValue, let integer = Int(exactly: number) else { throw .invalidField(field: field, problem: .notInteger) }
    return integer
  }

  static func minuteOfDay(_ value: JSONValue, field: String) throws(CommandRefusal) -> Int {
    let minute = try integer(value, field: field)
    try checkMinute(minute, field: field)
    return minute
  }

  static func checkMinute(_ minute: Int, field: String) throws(CommandRefusal) {
    guard (0...1439).contains(minute) else { throw .invalidField(field: field, problem: .outOfRange) }
  }

  /// An object member, read with its fields named `<prefix><key>.<field>`; absent or not an object is refused under the key.
  mutating func object(_ key: String) throws(CommandRefusal) -> PayloadReader {
    guard let value = value(key) else { throw .invalidField(field: field(key), problem: .required) }
    guard let members = value.objectValue else { throw .invalidField(field: field(key), problem: .notObject) }
    return PayloadReader(members, prefix: "\(field(key)).")
  }

  func finish() throws(CommandRefusal) {
    if let stray = members.keys.filter({ !consumed.contains($0) }).min(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
      throw .unexpectedField(field(stray))
    }
  }
}

struct PayloadWriter {
  private(set) var members: [String: JSONValue] = [:]

  mutating func put(_ key: String, _ value: (some StoredValue)?) {
    members[key] = value?.stored
  }

  mutating func put(_ key: String, token: (some RuleKey)?) {
    members[key] = token.map { .string($0.rawValue) }
  }

  mutating func putNull(_ key: String) {
    members[key] = .null
  }

  mutating func put(_ key: String, _ object: PayloadWriter) {
    members[key] = .object(object.members)
  }

  mutating func put(_ key: String, json: JSONValue) {
    members[key] = json
  }
}

import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// A domain read or write inside a content handler. A record this device cannot read is refused as unreadable, never taken for an absent one: named by
/// `artifact` when it is `record`, else by its kind and key.
func handlerDomain<Value>(_ artifact: String, _ record: EntityRef?, _ body: () throws(DomainError) -> Value) throws(ApplyError) -> Value {
  do throws(DomainError) {
    return try body()
  } catch {
    guard case .unreadable(let ref) = error else { throw .domain(error) }
    throw .unreadable(ref: ref == record ? artifact : "\(ref.kind.rawValue)/\(ref.key.rawValue)")
  }
}

func handlerDomain<Value>(_ body: () throws(DomainError) -> Value) throws(ApplyError) -> Value {
  do throws(DomainError) {
    return try body()
  } catch {
    guard case .unreadable(let ref) = error else { throw .domain(error) }
    throw .unreadable(ref: "\(ref.kind.rawValue)/\(ref.key.rawValue)")
  }
}

func handlerStore<Value>(_ body: () throws(StoreError) -> Value) throws(ApplyError) -> Value {
  do throws(StoreError) {
    return try body()
  } catch {
    throw .store(error)
  }
}

/// Code unit for code unit, as the store and the content hash compare: Swift's `==` takes canonically equivalent texts for equal.
func sameRevision<Body: RevisionBody>(_ left: Body, _ right: Body) -> Bool {
  OrderedJSON(left.json) == OrderedJSON(right.json)
}

/// The members of a stored inverse, read strictly: a member the capture always writes and that is missing or of the wrong type makes the inverse malformed.
struct InverseMembers {
  let record: OrderedJSONObject

  init(_ record: OrderedJSONObject) {
    self.record = record
  }

  var type: OpType? { record["op"]?.stringValue.flatMap { OpType(exactly: $0) } }

  func required<Value>(_ key: String, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value {
    guard let value = record[key].flatMap(convert) else { throw .malformedInverse }
    return value
  }

  func nullable<Value>(_ key: String, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value? {
    guard let raw = record[key] else { throw .malformedInverse }
    return try Self.nullable(raw, convert)
  }

  static func nullable<Value>(_ raw: OrderedJSON, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value? {
    if raw.isNull { return nil }
    guard let value = convert(raw) else { throw .malformedInverse }
    return value
  }

  func string(_ key: String) throws(ApplyRefusal) -> String { try required(key, \.stringValue) }

  func nullableString(_ key: String) throws(ApplyRefusal) -> String? { try nullable(key, \.stringValue) }

  func nullableStrings(_ key: String) throws(ApplyRefusal) -> [String]? { try nullable(key, inverseStrings) }

  func bool(_ key: String) throws(ApplyRefusal) -> Bool { try required(key, inverseBool) }
}

func inverseStrings(_ value: OrderedJSON) -> [String]? {
  guard let items = value.arrayValue else { return nil }
  let strings = items.compactMap(\.stringValue)
  return strings.count == items.count ? strings : nil
}

func inverseBool(_ value: OrderedJSON) -> Bool? {
  guard case .bool(let flag) = value else { return nil }
  return flag
}

func inverseInt(_ value: OrderedJSON) -> Int? {
  guard case .int(let number) = value else { return nil }
  return Int(exactly: number)
}

/// The stored form of a captured object, nil when the vault cannot hold it exactly.
func storableObject(_ value: OrderedJSON) -> [String: JSONValue]? {
  guard case .object(let members)? = value.storable else { return nil }
  return members
}

func inverseText(_ text: String?) -> OrderedJSON { text.map(OrderedJSON.string) ?? .null }

func inverseList(_ list: [String]?) -> OrderedJSON { list.map { .array($0.map(OrderedJSON.string)) } ?? .null }

func inverseOp(_ type: OpType, _ pairs: [(String, OrderedJSON)]) -> OrderedJSONObject {
  jsonRecord([("op", .string(type.rawValue))] + pairs)
}

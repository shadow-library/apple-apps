enum OpValue<Value: Sendable & Equatable>: Sendable, Equatable {
  case omitted
  case null
  case set(Value)

  var value: Value? {
    guard case .set(let value) = self else { return nil }
    return value
  }
}

struct OpFields {
  let record: OrderedJSONObject

  func string(_ key: String) -> String? { record[key]?.stringValue }

  func int(_ key: String) -> Int? { record[key]?.numberValue.map(JSNumber.integer) }

  func bool(_ key: String) -> Bool? {
    guard case .bool(let flag)? = record[key] else { return nil }
    return flag
  }

  func strings(_ key: String) -> [String]? { record[key]?.arrayValue?.compactMap(\.stringValue) }

  func object(_ key: String) -> OrderedJSONObject? { record[key]?.objectValue }

  func member<Value: RawRepresentable & CaseIterable>(_ key: String) -> Value? where Value.RawValue == String { Value(exactly: record[key]) }

  func patch<Value: Sendable & Equatable>(_ key: String, _ convert: (OrderedJSON) -> Value?) -> OpValue<Value> {
    guard let raw = record[key] else { return .omitted }
    if raw.isNull { return .null }
    return convert(raw).map(OpValue.set) ?? .omitted
  }

  func patchString(_ key: String) -> OpValue<String> { patch(key, \.stringValue) }

  func patchInt(_ key: String) -> OpValue<Int> { patch(key) { $0.numberValue.map(JSNumber.integer) } }

  func patchStrings(_ key: String) -> OpValue<[String]> { patch(key) { $0.arrayValue?.compactMap(\.stringValue) } }
}

struct OpEncoder {
  private(set) var pairs: [(key: String, value: OrderedJSON)] = []

  mutating func put(_ key: String, _ value: OrderedJSON?) {
    guard let value else { return }
    pairs.append((key: key, value: value))
  }

  mutating func string(_ key: String, _ value: String?) { put(key, value.map(OrderedJSON.string)) }

  mutating func int(_ key: String, _ value: Int?) { put(key, value.map { .int(Int64($0)) }) }

  mutating func bool(_ key: String, _ value: Bool?) { put(key, value.map(OrderedJSON.bool)) }

  mutating func strings(_ key: String, _ value: [String]?) { put(key, value.map { .array($0.map(OrderedJSON.string)) }) }

  mutating func patch<Value: Sendable & Equatable>(_ key: String, _ value: OpValue<Value>, _ encode: (Value) -> OrderedJSON) {
    switch value {
    case .omitted: break
    case .null: put(key, .null)
    case .set(let value): put(key, encode(value))
    }
  }

  mutating func patchString(_ key: String, _ value: OpValue<String>) { patch(key, value, OrderedJSON.string) }

  mutating func patchInt(_ key: String, _ value: OpValue<Int>) { patch(key, value) { .int(Int64($0)) } }

  mutating func patchStrings(_ key: String, _ value: OpValue<[String]>) { patch(key, value) { .array($0.map(OrderedJSON.string)) } }
}

func jsonObject(_ pairs: [(String, OrderedJSON)]) -> OrderedJSON {
  .object(OrderedJSONObject(pairs.map { (key: $0.0, value: $0.1) }))
}

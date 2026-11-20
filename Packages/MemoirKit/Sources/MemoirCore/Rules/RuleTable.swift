public typealias RuleKey = CaseIterable & Hashable & RawRepresentable<String> & Sendable

public struct RuleTable<Key: RuleKey, Value: Sendable>: Sendable {
  private let keys: [Key]
  private var values: [Value]

  public init(_ value: (Key) -> Value) {
    keys = Array(Key.allCases)
    values = keys.map(value)
  }

  public subscript(key: Key) -> Value {
    get { values[index(of: key)] }
    set { values[index(of: key)] = newValue }
  }

  public var entries: [(key: Key, value: Value)] {
    zip(keys, values).map { (key: $0, value: $1) }
  }

  private func index(of key: Key) -> Int {
    keys.firstIndex(of: key) ?? 0
  }
}

extension RuleTable: Equatable where Value: Equatable {}

extension RuleTable: Hashable where Value: Hashable {}

extension RuleTable: Encodable where Value: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: RawKey.self)
    for (key, value) in entries { try container.encode(value, forKey: RawKey(key.rawValue)) }
  }
}

struct RawKey: CodingKey {
  let stringValue: String

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  var intValue: Int? { nil }

  init?(intValue: Int) {
    nil
  }
}

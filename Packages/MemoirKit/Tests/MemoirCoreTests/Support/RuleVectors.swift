import Foundation
import MemoirCore
import Testing

enum FixtureError: Error, CustomStringConvertible {
  case malformed(String)

  var description: String {
    switch self {
    case .malformed(let detail): "Malformed fixture value: \(detail)"
    }
  }
}

/// A JSON value from a reference fixture, or a native rule output built for comparison with one.
indirect enum FixtureValue: Decodable, Equatable, CustomStringConvertible {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([FixtureValue])
  case object([String: FixtureValue])
  case fraction(Fraction)

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let flag = try? container.decode(Bool.self) {
      self = .bool(flag)
    } else if let number = try? container.decode(Int.self) {
      self = .int(number)
    } else if let number = try? container.decode(Double.self) {
      self = .double(number)
    } else if let text = try? container.decode(String.self) {
      self = .string(text)
    } else if let items = try? container.decode([FixtureValue].self) {
      self = .array(items)
    } else {
      self = .object(try container.decode([String: FixtureValue].self))
    }
  }

  var description: String {
    switch self {
    case .null: "null"
    case .bool(let flag): "\(flag)"
    case .int(let number): "\(number)"
    case .double(let number): "\(number)"
    case .string(let text): "\"\(text)\""
    case .array(let items): "[\(items.map(\.description).joined(separator: ","))]"
    case .object(let members): "{\(members.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))}"
    case .fraction(let fraction): "\(fraction)"
    }
  }

  subscript(key: String) -> FixtureValue {
    get throws {
      guard case .object(let members) = self, let value = members[key] else { throw FixtureError.malformed("no \(key) in \(self)") }
      return value
    }
  }

  var int: Int {
    get throws {
      guard case .int(let number) = self else { throw FixtureError.malformed("\(self) is not an integer") }
      return number
    }
  }

  var optionalInt: Int? {
    get throws {
      if case .null = self { return nil }
      return try int
    }
  }

  var bool: Bool {
    get throws {
      guard case .bool(let flag) = self else { throw FixtureError.malformed("\(self) is not a boolean") }
      return flag
    }
  }

  var string: String {
    get throws {
      guard case .string(let text) = self else { throw FixtureError.malformed("\(self) is not a string") }
      return text
    }
  }

  var array: [FixtureValue] {
    get throws {
      guard case .array(let items) = self else { throw FixtureError.malformed("\(self) is not an array") }
      return items
    }
  }

  func key<Key: RawRepresentable<String>>(_ type: Key.Type = Key.self) throws -> Key {
    guard let key = Key(rawValue: try string) else { throw FixtureError.malformed("\(self) is not a \(Key.self)") }
    return key
  }

  /// A reference crown weight is a JavaScript number that must be a whole number of halves.
  var halves: Halves {
    get throws {
      switch self {
      case .int(let number): return Halves(number * 2)
      case .double(let number) where (number * 2).rounded() == number * 2: return Halves(Int(number * 2))
      default: throw FixtureError.malformed("\(self) is not a whole number of halves")
      }
    }
  }

  static func ints(_ values: [Int]) -> FixtureValue {
    .array(values.map(FixtureValue.int))
  }

  static func keys<Key: RawRepresentable<String>>(_ values: [Key]) -> FixtureValue {
    .array(values.map { .string($0.rawValue) })
  }

  static func key<Key: RawRepresentable<String>>(_ value: Key?) -> FixtureValue {
    value.map { .string($0.rawValue) } ?? .null
  }

  /// A native exact value agrees with a reference float when the float is the nearest double to it,
  /// and with an exact model value (`{"fraction":[n,d]}`) only when they are the same rational.
  func matches(_ expected: FixtureValue) -> Bool {
    switch (self, expected) {
    case (.fraction(let native), .double(let reference)): return Double(native.numerator) / Double(native.denominator) == reference
    case (.fraction(let native), .int(let reference)): return native.denominator == 1 && native.numerator == reference
    case (.fraction(let native), .object(let members)):
      guard members.count == 1, case .array(let parts)? = members["fraction"], parts == [.int(native.numerator), .int(native.denominator)] else { return false }
      return true
    case (.array(let native), .array(let reference)):
      return native.count == reference.count && zip(native, reference).allSatisfy { $0.matches($1) }
    case (.object(let native), .object(let reference)):
      return native.count == reference.count && native.allSatisfy { key, value in reference[key].map(value.matches) ?? false }
    default:
      return self == expected
    }
  }
}

struct RuleCase: Decodable {
  let id: String
  let input: FixtureValue
  let output: FixtureValue
}

struct Divergence: Decodable {
  let file: String
  let function: String
  let id: String
  let fields: [String]
  let reference: FixtureValue
  let exact: FixtureValue
}

struct DivergenceList: Decodable {
  let count: Int
  let cases: [Divergence]
}

enum RuleVectors {
  static let divergences: DivergenceList = {
    do {
      return try JSONDecoder().decode(DivergenceList.self, from: data("rules/divergences.json"))
    } catch {
      Issue.record("divergences.json does not load: \(error)")
      return DivergenceList(count: 0, cases: [])
    }
  }()

  static func data(_ path: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent("Fixtures").appendingPathComponent(path))
  }

  static func cases(_ file: String, _ function: String) throws -> [RuleCase] {
    let groups = try JSONDecoder().decode([String: [RuleCase]].self, from: data("rules/\(file)"))
    guard let cases = groups[function], !cases.isEmpty else { throw FixtureError.malformed("\(file) has no \(function) cases") }
    return cases
  }

  /// Every vector must agree with the reference, except a listed divergence, which must agree with the exact model and not with the reference.
  static func check(
    _ file: String, _ function: String, sourceLocation: SourceLocation = #_sourceLocation, evaluate: (FixtureValue) throws -> FixtureValue
  ) throws {
    let listed = Dictionary(uniqueKeysWithValues: divergences.cases.filter { $0.file == file && $0.function == function }.map { ($0.id, $0) })
    var mismatches: [String] = []
    var visited = Set<String>()
    for vector in try cases(file, function) {
      let native = try evaluate(vector.input)
      guard let divergence = listed[vector.id] else {
        if !native.matches(vector.output) { mismatches.append("\(vector.id): native \(native) reference \(vector.output) for \(vector.input)") }
        continue
      }
      visited.insert(vector.id)
      if !native.matches(divergence.exact) { mismatches.append("\(vector.id): native \(native) exact \(divergence.exact)") }
      if native.matches(vector.output) { mismatches.append("\(vector.id): listed as divergent but native matches the reference \(vector.output)") }
    }
    #expect(visited == Set(listed.keys), "divergences name vectors that do not exist", sourceLocation: sourceLocation)
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(10).joined(separator: "\n"))", sourceLocation: sourceLocation)
  }
}

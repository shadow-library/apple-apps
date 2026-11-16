import ShadowCore

@testable import NovelForgeCore

struct FixtureShapeError: Error, CustomStringConvertible {
  let description: String
}

enum RuleFixture {
  static func load(_ name: String) throws -> JSONValue {
    try ReferenceFixture.decode(JSONValue.self, from: "rules/\(name).json")
  }

  static func section(_ name: String, _ key: String) throws -> [JSONValue] {
    try load(name)[key].orThrow("section \(key)").list()
  }
}

extension Optional {
  func orThrow(_ what: String) throws -> Wrapped {
    guard let self else { throw FixtureShapeError(description: "missing \(what)") }
    return self
  }
}

extension JSONValue {
  func list() throws -> [JSONValue] {
    try arrayValue.orThrow("array in \(self)")
  }

  func int() throws -> Int {
    try Int(intValue.orThrow("int in \(self)"))
  }

  func string() throws -> String {
    try stringValue.orThrow("string in \(self)")
  }

  func bool() throws -> Bool {
    try boolValue.orThrow("bool in \(self)")
  }

  func ints() throws -> [Int] {
    try list().map { try $0.int() }
  }

  func strings() throws -> [String] {
    try list().map { try $0.string() }
  }

  func optionalInt() throws -> Int? {
    isNull ? nil : try int()
  }

  func optionalString() throws -> String? {
    isNull ? nil : try string()
  }

  func at(_ index: Int) throws -> JSONValue {
    try self[index].orThrow("element \(index) of \(self)")
  }
}

func mismatches(_ cases: [JSONValue], _ check: (JSONValue) throws -> Bool) throws -> [Int] {
  try cases.indices.filter { try !check(cases[$0]) }
}

extension Array where Element == JSONValue {
  func strings() throws -> [String] {
    try map { try $0.string() }
  }
}

func parseJSON(_ text: String) -> OrderedJSON? {
  try? OrderedJSON(parsing: text)
}

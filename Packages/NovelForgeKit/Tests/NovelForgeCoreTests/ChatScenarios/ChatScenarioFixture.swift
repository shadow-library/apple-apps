import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

/// A deliberate deviation at one value of one step's outcome; the reference value must still be the fixture's.
struct ChatScenarioDifference: Sendable {
  let step: Int
  let path: [JSONValue]
  let reference: JSONValue
  let native: JSONValue
  let why: String
}

struct ChatScenario: Sendable {
  let name: String
  let vault: JSONValue
  let watch: [String]
  let steps: [JSONValue]
  let expected: [JSONValue]
  let differences: [ChatScenarioDifference]

  func expectation(at step: Int) -> Result<JSONValue, ChatScenarioMismatch> {
    var outcome = expected[step]
    var stale = [String]()
    for difference in differences where difference.step == step {
      let found = outcome.value(at: difference.path) ?? .null
      if !ChatScenarioJSON.same(found, difference.reference) { stale.append("\(difference.path): the reference now holds \(found), not \(difference.reference)") }
      outcome = outcome.setting(difference.native, at: difference.path)
    }
    return stale.isEmpty ? .success(outcome) : .failure(ChatScenarioMismatch(lines: stale))
  }
}

struct ChatScenarioMismatch: Error, CustomStringConvertible {
  let lines: [String]

  var description: String { lines.joined(separator: "\n") }
}

struct ChatScenarioWorld: Sendable {
  let premise: String?
  let storyCursor: Int
  let finalBody: String
  let draft: String
  let entities: [JSONValue]
  let milestones: [JSONValue]
}

enum ChatScenarioFixture {
  static func required<Value>(_ value: Value?, _ what: String = "a fixture member") throws -> Value {
    guard let value else { throw ChatScenarioMismatch(lines: ["the fixture has no \(what)"]) }
    return value
  }

  static let path = "chat-turns/chat-turns.json"

  static func load() throws -> (world: ChatScenarioWorld, scenarios: [ChatScenario]) {
    let root = try ReferenceFixture.decode(JSONValue.self, from: path)
    let world = try required(root["world"])
    let scenarios = try (root["scenarios"]?.arrayValue ?? []).map(scenario)
    return (
      ChatScenarioWorld(
        premise: world["premise"]?.stringValue, storyCursor: Int(try required(world["storyCursor"]?.intValue)), finalBody: try required(world["finalBody"]?.stringValue),
        draft: try required(world["draft"]?.stringValue), entities: world["entities"]?.arrayValue ?? [], milestones: world["milestones"]?.arrayValue ?? []),
      scenarios
    )
  }

  static let names: [String] = (try? load().scenarios.map(\.name)) ?? []

  private static func scenario(_ json: JSONValue) throws -> ChatScenario {
    let differences = try (json["differences"]?.arrayValue ?? []).map { difference in
      ChatScenarioDifference(
        step: Int(try required(difference["step"]?.intValue)), path: try required(difference["path"]?.arrayValue), reference: difference["reference"] ?? .null,
        native: difference["native"] ?? .null, why: try required(difference["why"]?.stringValue))
    }
    return ChatScenario(
      name: try required(json["name"]?.stringValue), vault: json["vault"] ?? [:], watch: (json["watch"]?.arrayValue ?? []).compactMap(\.stringValue),
      steps: json["steps"]?.arrayValue ?? [], expected: json["expected"]?.arrayValue ?? [], differences: differences)
  }
}

/// Strings compare by UTF-16 code units, as the reference compares them.
enum ChatScenarioJSON {
  static func same(_ left: JSONValue, _ right: JSONValue) -> Bool {
    var lines = [String]()
    compare(left, right, at: "", into: &lines)
    return lines.isEmpty
  }

  static func compare(_ expected: JSONValue, _ actual: JSONValue, at path: String, into lines: inout [String]) {
    switch (expected, actual) {
    case (.string(let left), .string(let right)):
      if JSString(left) != JSString(right) { lines.append("\(path): expected \(expected), found \(actual)") }
    case (.array(let left), .array(let right)):
      guard left.count == right.count else {
        lines.append("\(path): expected \(left.count) items \(expected), found \(right.count) \(actual)")
        return
      }
      for (index, pair) in zip(left, right).enumerated() { compare(pair.0, pair.1, at: "\(path)[\(index)]", into: &lines) }
    case (.object(let left), .object(let right)):
      for key in Set(left.keys).union(right.keys).sorted() {
        guard let want = left[key] else {
          lines.append("\(path).\(key): not expected, found \(right[key] ?? .null)")
          continue
        }
        guard let found = right[key] else {
          lines.append("\(path).\(key): expected \(want), missing")
          continue
        }
        compare(want, found, at: "\(path).\(key)", into: &lines)
      }
    default:
      if expected != actual { lines.append("\(path): expected \(expected), found \(actual)") }
    }
  }
}

extension JSONValue {
  fileprivate func value(at path: [JSONValue]) -> JSONValue? {
    guard let first = path.first else { return self }
    let child: JSONValue? =
      switch first {
      case .string(let key): self[key]
      case .int(let index): self[Int(index)]
      default: nil
      }
    return child?.value(at: Array(path.dropFirst()))
  }

  fileprivate func setting(_ value: JSONValue, at path: [JSONValue]) -> JSONValue {
    guard let first = path.first else { return value }
    let rest = Array(path.dropFirst())
    switch (self, first) {
    case (.object(var members), .string(let key)):
      members[key] = (members[key] ?? .null).setting(value, at: rest)
      return .object(members)
    case (.array(var items), .int(let index)) where items.indices.contains(Int(index)):
      items[Int(index)] = items[Int(index)].setting(value, at: rest)
      return .array(items)
    case (.null, .string(let key)):
      return .object([key: JSONValue.null.setting(value, at: rest)])
    default:
      return self
    }
  }
}

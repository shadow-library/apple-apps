import Foundation

@testable import NovelForgeCore

enum PromptFixture {
  static let root: OrderedJSON = {
    do { return try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("prompts/prompts.json"), as: UTF8.self)) } catch {
      preconditionFailure("prompts.json is unreadable: \(error)")
    }
  }()

  static func path(_ keys: String...) -> OrderedJSON {
    keys.reduce(root) { $0.pField($1) }
  }

  static func cases(_ keys: String...) -> [OrderedJSON] {
    keys.reduce(root) { $0.pField($1) }.pItems
  }
}

extension OrderedJSON {
  func pField(_ key: String) -> OrderedJSON { objectValue?[key] ?? .null }

  var pItems: [OrderedJSON] { arrayValue ?? [] }

  var pText: String { stringValue ?? "" }

  var pFlag: Bool {
    guard case .bool(let value) = self else { return false }
    return value
  }

  var pStrings: [String] { pItems.map(\.pText) }

  var pMessages: [PromptMessage] { pItems.map { PromptMessage(PromptMessage.Role(rawValue: $0.pField("role").pText) ?? .system, $0.pField("text").pText) } }
}

func sameText(_ actual: String, _ expected: String) -> Bool { actual.jsEquals(expected) }

func sameMessages(_ actual: [PromptMessage], _ expected: [PromptMessage]) -> Bool {
  actual.count == expected.count && zip(actual, expected).allSatisfy { $0.role == $1.role && sameText($0.text, $1.text) }
}

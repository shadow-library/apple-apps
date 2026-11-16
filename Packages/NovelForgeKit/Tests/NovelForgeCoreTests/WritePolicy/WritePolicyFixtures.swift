import Foundation

@testable import NovelForgeCore

struct QuoteFixtureToken: Decodable {
  let units: QuoteToken

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      units = text.jsCodeUnits
    } else {
      units = try container.decode([UInt16].self)
    }
  }
}

struct QuoteTextCase: Decodable {
  let text: String
  let normalised: String
  let tokens: [QuoteToken]
  let sentences: [String]
  let tentative: [Bool]
  let stated: Set<QuoteToken>
  let hedged: Set<QuoteToken>

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    normalised = try container.decode(String.self)
    tokens = try container.decode([QuoteFixtureToken].self).map(\.units)
    sentences = try container.decode([String].self)
    tentative = try container.decode(String.self).map { $0 == "1" }
    stated = Set(try container.decode([QuoteFixtureToken].self).map(\.units))
    hedged = Set(try container.decode([QuoteFixtureToken].self).map(\.units))
  }
}

struct QuoteCase: Decodable {
  let quote: String
  let text: String
  let found: Bool
  let tentative: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    quote = try container.decode(String.self)
    text = try container.decode(String.self)
    found = try container.decode(Bool.self)
    tentative = try container.decode(Bool.self)
  }
}

struct QuoteTextFixture: Decodable {
  let texts: [QuoteTextCase]
  let quotes: [QuoteCase]

  static func load() throws -> QuoteTextFixture {
    try ReferenceFixture.decode(QuoteTextFixture.self, from: "write-policy/text.json")
  }
}

struct WritePolicyOpExpectation: Decodable {
  let alwaysCardRule: String?
  let ideaCardRule: String?
  let isPlannerSide: Bool
  let references: [String]
  let launders: Bool
  let exceedsNovelty: Bool
  let exceedsRemoval: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    alwaysCardRule = try container.decodeNil() ? nil : container.decode(String.self)
    ideaCardRule = try container.decodeNil() ? nil : container.decode(String.self)
    isPlannerSide = try container.decode(Bool.self)
    references = try container.decode([String].self)
    launders = try container.decode(Bool.self)
    exceedsNovelty = try container.decode(Bool.self)
    exceedsRemoval = try container.decode(Bool.self)
  }
}

struct WritePolicyCase: Decodable {
  let ops: String
  let message: String
  let vocabulary: String?
  let mode: String
  let ideas: String?
  let justDiscussing: Bool?
  let hold: String
  let current: [[String]]
  let dispositions: [String]
  let held: String
  let sources: [String]
  let perOp: [WritePolicyOpExpectation]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    ops = try container.decode(String.self)
    message = try container.decode(String.self)
    vocabulary = try container.decodeNil() ? nil : container.decode(String.self)
    mode = try container.decode(String.self)
    ideas = try container.decodeNil() ? nil : container.decode(String.self)
    justDiscussing = try container.decodeNil() ? nil : container.decode(Bool.self)
    hold = try container.decode(String.self)
    current = try container.decode([[String]].self)
    dispositions = try container.decode([String].self)
    held = try container.decode(String.self)
    sources = try container.decode([String].self)
    perOp = try container.decode([WritePolicyOpExpectation].self)
  }

  var changeOps: [ChangeOp] {
    get throws { try parseChangeSet(try OrderedJSON(parsing: ops), options: ChangeSetValidationOptions(entityMaterialization: false)) }
  }

  var state: WritePolicyState {
    get throws {
      WritePolicyState(
        current: try current.map { pair in
          guard pair.count == 2, let ref = pair.first, let text = pair.last, let fields = try OrderedJSON(parsing: text).objectValue else {
            throw WritePolicyFixtureError.malformed("current \(pair)")
          }
          return (ref: ref, fields: fields)
        }
      )
    }
  }

  var input: WritePolicyInput {
    get throws {
      guard let chatMode = RefinementChatMode(rawValue: mode) else { throw WritePolicyFixtureError.malformed("mode \(mode)") }
      guard let writeHold = WriteHold(rawValue: hold) else { throw WritePolicyFixtureError.malformed("hold \(hold)") }
      let handling = try ideas.map { raw in
        guard let handling = IdeaHandling(rawValue: raw) else { throw WritePolicyFixtureError.malformed("ideas \(raw)") }
        return handling
      }
      return WritePolicyInput(
        ops: try changeOps,
        authorMessage: message,
        vocabulary: vocabulary,
        mode: chatMode,
        ideas: handling,
        justDiscussing: justDiscussing ?? false,
        hold: writeHold,
        state: try state
      )
    }
  }
}

enum WritePolicyFixtureError: Error {
  case malformed(String)
}

struct WritePolicyTablesFixture: Decodable {
  let direct: [String]
  let alwaysCard: [[String]]
  let ideaPolicy: [[String]]
  let sources: [String]
}

struct WritePolicyFixture: Decodable {
  let tables: WritePolicyTablesFixture
  let cases: [WritePolicyCase]

  static func load() throws -> WritePolicyFixture {
    try ReferenceFixture.decode(WritePolicyFixture.self, from: "write-policy/policy.json")
  }
}

extension OpDisposition {
  var encoded: String {
    switch self {
    case .direct(_, let source): "d:\(source.rawValue)"
    case .card(_, let reason, let rule?): "c:\(reason.rawValue):\(rule.rawValue)"
    case .card(_, let reason, nil): "c:\(reason.rawValue)"
    }
  }
}

enum CodeUnitStrings {
  static func equal(_ left: [String], _ right: [String]) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { $0.jsEquals($1) }
  }
}

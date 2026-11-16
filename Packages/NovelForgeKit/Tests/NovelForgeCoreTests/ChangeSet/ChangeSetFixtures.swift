import Foundation

@testable import NovelForgeCore

struct ChangeSetValidationCase: Decodable {
  let text: String
  let scope: Int
  let flag: Int
  let errors: [String]?
  let repaired: String?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    scope = try container.decode(Int.self)
    flag = try container.decode(Int.self)
    errors = try container.decodeNil() ? nil : container.decode([String].self)
    repaired = try? container.decode(String.self)
  }

  var input: OrderedJSON {
    get throws { try OrderedJSON(parsing: text) }
  }

  var expectedValue: OrderedJSON {
    get throws { try OrderedJSON(parsing: repaired ?? text) }
  }
}

struct ChangeSetValidationFixture: Decodable {
  let scopes: [[String]?]
  let cases: [ChangeSetValidationCase]

  func allowedOps(_ scope: Int) -> [OpType]? {
    scopes[scope]?.compactMap { OpType(exactly: $0) }
  }

  func run(_ item: ChangeSetValidationCase) throws -> ChangeSetValidation {
    let input = try item.input
    if item.flag == 2 { return validatePluginChangeSet(input) }
    return validateChangeSet(input, allowedOps: allowedOps(item.scope), options: ChangeSetValidationOptions(entityMaterialization: item.flag != 1))
  }

  static func load() throws -> ChangeSetValidationFixture {
    try ReferenceFixture.decode(ChangeSetValidationFixture.self, from: "change-set/validation.json")
  }
}

struct ChangeSetOptionalCase: Decodable {
  let text: String?
  let scope: Int
  let result: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decodeNil() ? nil : container.decode(String.self)
    scope = try container.decode(Int.self)
    _ = try container.decode(Int.self)
    result = try container.decode(String.self)
  }
}

struct ChangeSetOptionalFixture: Decodable {
  let cases: [ChangeSetOptionalCase]
}

struct ChangeSetVocabularyCase: Decodable {
  let ops: [String]
  let option: Int
  let lines: [Int]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    ops = try container.decode([String].self)
    option = try container.decode(Int.self)
    lines = try container.decode([Int].self)
  }
}

struct ChangeSetActionCase: Decodable {
  let actions: [String]
  let lines: [Int]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    actions = try container.decode([String].self)
    lines = try container.decode([Int].self)
  }
}

struct ChangeSetVocabularyFixture: Decodable {
  let dictionary: [String]
  let ops: [ChangeSetVocabularyCase]
  let actions: [ChangeSetActionCase]

  func text(_ lines: [Int]) -> String {
    lines.map { dictionary[$0] }.joined(separator: "\n")
  }

  static func load() throws -> ChangeSetVocabularyFixture {
    try ReferenceFixture.decode(ChangeSetVocabularyFixture.self, from: "change-set/vocabulary.json")
  }
}

struct ChangeSetRefsCase: Decodable {
  let text: String
  let refs: [String]
  let keys: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    refs = try container.decode([String].self)
    keys = try container.decode([String].self)
  }
}

struct ChangeSetRefsFixture: Decodable {
  let cases: [ChangeSetRefsCase]
}

struct ChangeSetSpecField: Decodable {
  let name: String
  let kind: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    name = try container.decode(String.self)
    kind = try container.decode(String.self)
  }
}

struct ChangeSetSpecEntry: Decodable {
  let op: String
  let required: [ChangeSetSpecField]
  let optional: [ChangeSetSpecField]
  let description: String?
  let declared: [String]
  let isAction: Bool
  let hidden: [[String]]
}

struct ChangeSetRejection: Decodable {
  let code: String
  let message: String
}

struct ChangeSetSpecLists: Decodable {
  let sections: [String]
  let entityTypes: [String]
  let writeModes: [String]
  let contentModes: [String]
  let milestoneKinds: [String]
  let promiseKinds: [String]
  let promiseStatuses: [String]
  let scopes: [String]
}

struct ChangeSetSpecFixture: Decodable {
  let ops: [String]
  let actions: [String]
  let content: [String]
  let pluginAllowed: [String]
  let prototypeNames: [String]
  let rejection: ChangeSetRejection
  let lists: ChangeSetSpecLists
  let perOp: [ChangeSetSpecEntry]

  static func load() throws -> ChangeSetSpecFixture {
    try ReferenceFixture.decode(ChangeSetSpecFixture.self, from: "change-set/specs.json")
  }
}

func csParse(_ text: String) throws -> OrderedJSON {
  try OrderedJSON(parsing: text)
}

func csSameStrings(_ left: [String], _ right: [String]) -> Bool {
  left.count == right.count && zip(left, right).allSatisfy { $0.jsEquals($1) }
}

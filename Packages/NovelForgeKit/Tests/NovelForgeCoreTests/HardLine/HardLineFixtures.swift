import Foundation

@testable import NovelForgeCore

struct HardLineFixture: Decodable {
  let lexicon: [String: [[String]]]
  let systemLine: String
  let systemLineFindsNothing: Bool
  let find: [FindRow]
  let custom: [FindRow]
  let hits: [HitRow]
  let refusalKinds: [RefusalKindRow]
  let describe: [DescribeRow]
  let classification: [ClassificationRow]
  let roles: [RoleRow]
  let prototypeKeys: [PrototypeRow]
  let wire: [WireRow]
  let wireDeviations: [WireRow]
  let inputs: [InputRow]
  let outputs: [OutputRow]
  let sections: [SectionRow]

  static func load() throws -> HardLineFixture {
    try ReferenceFixture.decode(from: "hard-line/hard-line.json")
  }
}

struct FindRow: Decodable {
  let texts: [String]
  let scope: HardLineScope?
  let rule: HardLineRule?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    texts = try container.decode([String].self)
    scope = try container.decodeOptional(String.self).flatMap(HardLineScope.init(rawValue:))
    rule = try container.decodeOptional(String.self).flatMap(HardLineRule.init(rawValue:))
  }
}

struct ItemRow: Decodable {
  let item: ScreenedText

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let text = try container.decode(String.self)
    let scope = try container.decode(String.self)
    let source = try container.decode(String.self)
    item = ScreenedText(text: text, scope: HardLineScope(rawValue: scope) ?? .supplied, source: source, sourceRefs: try container.decodeOptional([String].self))
  }
}

struct HitRow: Decodable {
  let items: [ScreenedText]
  let hit: HardLineHit?
  let refusal: (code: String, message: String, status: Int)?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    items = try container.decode([ItemRow].self).map(\.item)
    hit = try container.decodeOptional(HitPayload.self).map(\.hit)
    refusal = try container.decodeOptional(RefusalPayload.self).map { ($0.code, $0.message, $0.status) }
  }
}

struct HitPayload: Decodable {
  let hit: HardLineHit

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let rule = try container.decode(String.self)
    hit = HardLineHit(rule: HardLineRule(rawValue: rule) ?? .standaloneTerm, source: try container.decode(String.self), sourceRefs: try container.decode([String].self))
  }
}

struct RefusalPayload: Decodable {
  let code: String
  let message: String
  let status: Int

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    code = try container.decode(String.self)
    message = try container.decode(String.self)
    status = try container.decode(Int.self)
  }
}

struct RefusalKindRow: Decodable {
  let kind: String
  let refusal: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    kind = try container.decode(String.self)
    refusal = try container.decode(Bool.self)
  }
}

struct DescribeRow: Decodable {
  let key: String
  let refs: [String]
  let label: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    refs = try container.decode([String].self)
    label = try container.decode(String.self)
  }
}

struct ScopeSource: Decodable {
  let scope: HardLineScope
  let source: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    scope = HardLineScope(rawValue: try container.decode(String.self)) ?? .supplied
    source = try container.decode(String.self)
  }
}

struct ClassificationRow: Decodable {
  let key: String
  let classified: Bool
  let screens: [ScopeSource]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    classified = try container.decode(Bool.self)
    screens = try container.decode([ScopeSource].self)
  }
}

struct RoleRow: Decodable {
  let role: String
  let scope: HardLineScope

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    role = try container.decode(String.self)
    scope = HardLineScope(rawValue: try container.decode(String.self)) ?? .supplied
  }
}

struct PrototypeRow: Decodable {
  let key: String
  let referenceClassified: Bool
  let referenceOutcome: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    referenceClassified = try container.decode(Bool.self)
    _ = try container.decode([[String]].self)
    referenceOutcome = try container.decode(String.self)
  }
}

struct WireRow: Decodable {
  let messages: [WireMessage]
  let texts: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    messages = try container.decode([FixtureJSON].self).map { message in
      WireMessage(content: HardLineContent(json: message.value.objectValue?["content"]))
    }
    texts = try container.decode([String].self)
  }
}

struct EntryRow: Decodable {
  let key: String
  let value: OrderedJSON

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    value = try container.decode(FixtureJSON.self).value
  }
}

struct ScreenRow: Decodable {
  let text: String
  let scope: HardLineScope
  let source: String
  let sourceRefs: [String]?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    scope = HardLineScope(rawValue: try container.decode(String.self)) ?? .supplied
    source = try container.decode(String.self)
    sourceRefs = container.isAtEnd ? nil : try container.decode([String].self)
  }
}

struct InputRow: Decodable {
  let input: OrderedJSONObject
  let screens: [ScreenRow]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    input = OrderedJSONObject(try container.decode([EntryRow].self).map { (key: $0.key, value: $0.value) })
    screens = try container.decode([ScreenRow].self)
  }
}

struct OutputRow: Decodable {
  let output: OrderedJSON
  let role: String
  let screens: [ScreenRow]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    output = try container.decode(FixtureJSON.self).value
    role = try container.decode(String.self)
    screens = try container.decode([ScreenRow].self)
  }
}

struct SectionRow: Decodable {
  let sections: [ContextSection]
  let screens: [ScreenRow]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    sections = try container.decode([SectionTriple].self).map(\.section)
    screens = try container.decode([ScreenRow].self)
  }
}

struct SectionTriple: Decodable {
  let section: ContextSection

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    section = ContextSection(key: try container.decode(String.self), rendered: try container.decode(String.self), sourceRefs: try container.decode([String].self))
  }
}

func sameScreens(_ actual: [ScreenedText], _ expected: [ScreenRow]) -> Bool {
  actual.count == expected.count
    && zip(actual, expected).allSatisfy { actual, expected in
      actual.text.jsEquals(expected.text) && actual.scope == expected.scope && actual.source.jsEquals(expected.source)
        && (expected.sourceRefs == nil ? actual.sourceRefs == nil : actual.sourceRefs.map { sameStrings($0, expected.sourceRefs ?? []) } ?? false)
    }
}

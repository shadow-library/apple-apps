import Foundation

@testable import NovelForgeCore

enum IdeaFixtureError: Error {
  case malformed(String)
}

struct FixtureText: Decodable {
  let value: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      value = text
    } else {
      value = JSText.string(fromCodeUnits: try container.decode([UInt16].self))
    }
  }
}

func parseOps(_ json: String) throws -> [ChangeOp] {
  try parseChangeSet(try OrderedJSON(parsing: json), options: ChangeSetValidationOptions(entityMaterialization: false))
}

struct IdeaIdCase: Decodable {
  let ops: String
  let ideaIds: [String]
  let labels: [String?]
  let stamped: [String?]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    ops = try container.decode(String.self)
    ideaIds = try container.decode([String].self)
    labels = try container.decode([FixtureText?].self).map { $0?.value }
    stamped = try container.decode([String?].self)
  }

  static func load() throws -> [IdeaIdCase] {
    try ReferenceFixture.decode([IdeaIdCase].self, from: "ideas/ids.json")
  }
}

struct IdeaFilterCase: Decodable {
  let ops: String
  let message: String
  let vocabulary: String?
  let mode: String
  let ideas: String?
  let justDiscussing: Bool?
  let hold: String
  let current: [[String]]
  let rejected: [String]
  let filterable: [String]
  let dropped: [String]
  let keptIndexes: [Int]
  let dispositions: [String]
  let held: String
  let sources: [String]
  let directCount: Int
  let cardCount: Int
  let unchanged: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    ops = try container.decode(String.self)
    message = try container.decode(String.self)
    vocabulary = try container.decode(String?.self)
    mode = try container.decode(String.self)
    ideas = try container.decode(String?.self)
    justDiscussing = try container.decode(Bool?.self)
    hold = try container.decode(String.self)
    current = try container.decode([[String]].self)
    rejected = try container.decode([String].self)
    filterable = try container.decode([String].self)
    dropped = try container.decode([String].self)
    keptIndexes = try container.decode([Int].self)
    dispositions = try container.decode([String].self)
    held = try container.decode(String.self)
    sources = try container.decode([String].self)
    directCount = try container.decode(Int.self)
    cardCount = try container.decode(Int.self)
    unchanged = try container.decode(Int.self) == 1
  }

  static func load() throws -> [IdeaFilterCase] {
    try ReferenceFixture.decode([IdeaFilterCase].self, from: "ideas/filter.json")
  }

  var state: WritePolicyState {
    get throws {
      WritePolicyState(
        current: try current.map { pair in
          guard pair.count == 2, let fields = try OrderedJSON(parsing: pair[1]).objectValue else { throw IdeaFixtureError.malformed("current \(pair)") }
          return (ref: pair[0], fields: fields)
        }
      )
    }
  }

  var input: WritePolicyInput {
    get throws {
      guard let chatMode = RefinementChatMode(rawValue: mode), let writeHold = WriteHold(rawValue: hold) else { throw IdeaFixtureError.malformed("mode \(mode) hold \(hold)") }
      let handling = try ideas.map { raw in
        guard let handling = IdeaHandling(rawValue: raw) else { throw IdeaFixtureError.malformed("ideas \(raw)") }
        return handling
      }
      return WritePolicyInput(
        ops: try parseOps(ops), authorMessage: message, vocabulary: vocabulary, mode: chatMode, ideas: handling, justDiscussing: justDiscussing ?? false, hold: writeHold,
        state: try state)
    }
  }
}

struct FixtureArtifactState: Decodable {
  let exists: Bool
  let revision: Int?
  let contentHash: String?

  var state: ArtifactState { ArtifactState(exists: exists, revision: revision, contentHash: contentHash) }
}

struct FixtureRejectionContext: Decodable {
  let activeVolumeKey: String?
  let states: [String: FixtureArtifactState]

  var context: RejectionContext {
    RejectionContext(activeVolumeKey: activeVolumeKey, states: Dictionary(uniqueKeysWithValues: states.map { (JSString($0.key), $0.value.state) }))
  }
}

struct RejectionScopeCase: Decodable {
  let context: Int
  let ideaId: String?
  let scope: String?
  let anchor: String
  let inScope: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    context = try container.decode(Int.self)
    ideaId = try container.decode(String?.self)
    scope = try container.decode(String?.self)
    anchor = try container.decode(String.self)
    inScope = try container.decode(Bool.self)
  }

  var entry: IdeaRejectionEntry {
    get throws {
      IdeaRejectionEntry(
        ideaId: ideaId, rejectionScope: scope.flatMap(LedgerRejectionScope.init(rawValue:)), rejectionAnchor: RejectionAnchor(json: try OrderedJSON(parsing: anchor)))
    }
  }
}

struct RejectionAnchorCase: Decodable {
  let scope: LedgerRejectionScope
  let context: Int
  let refs: [String]
  let anchor: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    scope = try container.decode(LedgerRejectionScope.self)
    context = try container.decode(Int.self)
    refs = try container.decode([String].self)
    anchor = try container.decode(String.self)
  }
}

struct RejectionRefsCase: Decodable {
  let entries: String
  let refs: [String]
  let wanted: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    entries = try container.decode(String.self)
    refs = try container.decode([String].self)
    wanted = try container.decode([String].self)
  }
}

struct RejectionLedgerCase: Decodable {
  let volumes: String
  let entries: String
  let ideaIds: [String]
  let rejected: [String]
  let keptIndexes: [Int]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    volumes = try container.decode(String.self)
    entries = try container.decode(String.self)
    ideaIds = try container.decode([String].self)
    rejected = try container.decode([String].self)
    keptIndexes = try container.decode([Int].self)
  }
}

struct RejectionFixture: Decodable {
  let contexts: [FixtureRejectionContext]
  let scopes: [RejectionScopeCase]
  let anchors: [RejectionAnchorCase]
  let refs: [RejectionRefsCase]
  let ledger: [RejectionLedgerCase]

  static func load() throws -> RejectionFixture {
    try ReferenceFixture.decode(RejectionFixture.self, from: "ideas/rejections.json")
  }
}

func parseLedgerEntries(_ json: String) throws -> [IdeaRejectionEntry] {
  guard let items = try OrderedJSON(parsing: json).arrayValue else { throw IdeaFixtureError.malformed("entries") }
  return try items.map { item in
    guard let record = item.objectValue else { throw IdeaFixtureError.malformed("entry") }
    return IdeaRejectionEntry(
      ideaId: record["ideaId"]?.stringValue, rejectionScope: record["rejectionScope"]?.stringValue.flatMap(LedgerRejectionScope.init(rawValue:)),
      rejectionAnchor: record["rejectionAnchor"].flatMap(RejectionAnchor.init(json:)))
  }
}

func parseLedgerVolumes(_ json: String) throws -> [RejectionVolume] {
  guard let items = try OrderedJSON(parsing: json).arrayValue else { throw IdeaFixtureError.malformed("volumes") }
  return try items.map { item in
    guard let record = item.objectValue, let key = record["volumeKey"]?.stringValue, let ordinal = record["ordinal"]?.numberValue, let raw = record["state"]?.stringValue,
      let state = VolumeState(rawValue: raw)
    else { throw IdeaFixtureError.malformed("volume") }
    return RejectionVolume(volumeKey: key, ordinal: Int(ordinal), state: state)
  }
}

struct NegationCase: Decodable {
  let before: String
  let after: String
  let exempt: [String]
  let echoes: [NegationEcho]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    before = try container.decode(String.self)
    after = try container.decode(String.self)
    exempt = try container.decode([String].self)
    var rows = try container.nestedUnkeyedContainer()
    var echoes: [NegationEcho] = []
    while !rows.isAtEnd {
      var row = try rows.nestedUnkeyedContainer()
      let terms = try row.decode([String].self)
      echoes.append(NegationEcho(terms: terms, excerpt: try row.decode(FixtureText.self).value))
    }
    self.echoes = echoes
  }
}

struct NegationRequestCase: Decodable {
  let message: String
  let terms: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    message = try container.decode(String.self)
    terms = try container.decode([String].self)
  }
}

struct NegationFixture: Decodable {
  let echoes: [NegationCase]
  let requests: [NegationRequestCase]

  static func load() throws -> NegationFixture {
    try ReferenceFixture.decode(NegationFixture.self, from: "ideas/negation.json")
  }
}

enum IdeaStrings {
  static func equal(_ left: [String], _ right: [String]) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { $0.jsEquals($1) }
  }
}

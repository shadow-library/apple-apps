import Foundation
import ShadowCore

@testable import NovelForgeCore

struct LookupText: Decodable, Sendable {
  struct Segment: Decodable, Sendable {
    let text: String

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let literal = try? container.decode(String.self) {
        text = literal
        return
      }
      let repeated = try container.decode(Repeated.self)
      text = String(String(repeating: repeated.unit, count: (repeated.length + repeated.unit.utf16.count - 1) / repeated.unit.utf16.count).prefix(repeated.length))
    }
  }

  struct Repeated: Decodable {
    let unit: String
    let length: Int
  }

  struct Recipe: Decodable {
    let recipe: [Segment]
  }

  let value: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let literal = try? container.decode(String.self) {
      value = literal
      return
    }
    value = try container.decode(Recipe.self).recipe.map(\.text).joined()
  }
}

struct LookupWorld: Decodable, Sendable {
  struct Page: Decodable, Sendable {
    let section: String
    let slug: String
    let revision: Int
    let frontmatter: [String: JSONValue]?
    let body: LookupText?
  }

  struct Entity: Decodable, Sendable {
    let entityKey: String
    let name: String
    let type: String
    let status: String?
    let body: LookupText?
    let notes: String?
  }

  struct Ending: Decodable, Sendable {
    let hookType: String
    let handoffState: String
    let openQuestion: String
    let emotionalBeat: String
    let mustNotResolve: [String]?
  }

  struct Learn: Decodable, Sendable {
    let factKey: String
    let entityKey: String
  }

  struct Knowledge: Decodable, Sendable {
    let pov: [String]
    let learns: [Learn]
  }

  struct Brief: Decodable, Sendable {
    let chapter: Int
    let volumeKey: String?
    let title: String?
    let body: LookupText
    let contextRefs: [String]?
    let pov: String?
    let endingContract: Ending?
    let knowledgeContract: Knowledge?
    let chapterPurpose: String?
    let readerValue: [String]?
    let repetitionRisks: [String]?
    let guidance: String?
    let writeMode: String
    let revision: Int
  }

  struct Draft: Decodable, Sendable {
    let chapter: Int
    let title: String?
    let revision: Int
    let summary: String?
    let body: LookupText
    let isolated: Bool
    let reviewStatus: String
  }

  struct Chapter: Decodable, Sendable {
    let number: Int
    let summary: String?
    let isolated: Bool
    let title: String?
    let disclosed: [String]
  }

  struct Volume: Decodable, Sendable {
    let volumeKey: String
    let ordinal: Int
    let title: String?
    let objective: String?
    let body: String?
  }

  struct Thread: Decodable, Sendable {
    let threadKey: String
    let status: String
    let openedChapter: Int?
    let closedChapter: Int?
    let summary: String?
    let payoffWindow: Int?
    let payoffMilestoneKey: String?
    let payoffVolumeKey: String?
    let intentionallyOpen: Bool
  }

  struct Fact: Decodable, Sendable {
    let factKey: String
    let text: String
    let unlock: JSONValue?
    let writerNote: String?
    let terms: [String]?
    let allowedClues: [String]?
  }

  struct Call: Decodable, Sendable {
    let task: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let nano: Int64
    let source: String
  }

  let pages: [Page]
  let entities: [Entity]
  let briefs: [Brief]
  let drafts: [Draft]
  let chapters: [Chapter]
  let volumes: [Volume]
  let threads: [Thread]
  let facts: [Fact]
  let notes: String?
  let usage: [Call]
}

struct ChatLookupFixture: Decodable {
  struct Definition: Decodable {
    let name: String
    let description: String
    let maxCallsPerRun: Int
    let tokensBudget: Int
    let arguments: [String]?
  }

  struct Lookup: Decodable {
    let tool: String
    let argsJSON: String?
  }

  struct Outcome: Decodable {
    let tool: String
    let status: String
    let trace: [String: LookupTraceValue]
    let traceStatus: String
  }

  struct Expected: Decodable {
    let text: String
    let plannerRead: Bool
    let outcomes: [Outcome]
  }

  struct Case: Decodable {
    let name: String
    let world: String
    let lookups: [Lookup]
    let expected: Expected
  }

  struct Guard: Decodable {
    let tool: String
    let argsJSON: String
    let expected: Bool
  }

  let bibleSections: [String]
  let definitions: [Definition]
  let scopeLines: [String]
  let worlds: [String: LookupWorld]
  let cases: [Case]
  let plannerGuard: [Guard]

  static func load() throws -> ChatLookupFixture {
    try ReferenceFixture.decode(from: "chat-lookups/chat-lookups.json")
  }
}

enum LookupTraceValue: Decodable, Equatable {
  case text(String)
  case count(Double)

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      self = .count(try container.decode(Double.self))
    }
  }

  init(_ value: ChatTraceValue) {
    switch value {
    case .text(let text): self = .text(text)
    case .count(let count): self = .count(count)
    }
  }
}

func parsedArguments(_ json: String?) throws -> OrderedJSONObject? {
  guard let json else { return nil }
  return try OrderedJSON(parsing: json).objectValue
}

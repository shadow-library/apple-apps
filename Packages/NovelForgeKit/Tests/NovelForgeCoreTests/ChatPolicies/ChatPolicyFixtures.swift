import Foundation
import ShadowText

@testable import NovelForgeCore

enum ChatFixtureError: Error {
  case malformed(String)
}

enum ChatFixture {
  static func load(_ name: String) throws -> OrderedJSON {
    let text = String(decoding: try ReferenceFixture.data("chat-policies/\(name)"), as: UTF8.self)
    return try OrderedJSON(parsing: text)
  }
}

extension OrderedJSON {
  var chatItems: [OrderedJSON] { arrayValue ?? [] }

  var chatText: String { stringValue ?? "" }

  var chatFlag: Bool {
    guard case .bool(let value) = self else { return false }
    return value
  }

  var chatCount: Int { Int(numberValue ?? 0) }

  var chatOps: [OrderedJSONObject] { chatItems.compactMap(\.objectValue) }

  var chatOpsIfPresent: [OrderedJSONObject]? {
    guard case .array = self else { return nil }
    return chatOps
  }
}

struct PassageInputFixture: Decodable {
  let chapter: Int
  let draftId: String
  let revision: Int
  let saveSeq: Int?
  let start: Int
  let end: Int
  let passageHash: String
  let quote: FixtureText
  let comment: FixtureText

  var input: PassageContextInput {
    PassageContextInput(
      chapter: chapter, draftId: draftId, revision: revision, saveSeq: saveSeq, start: start, end: end, passageHash: passageHash, quote: quote.value, comment: comment.value)
  }
}

struct PassageDraftFixture: Decodable {
  let id: String
  let chapter: Int
  let revision: Int
  let saveSeq: Int
  let body: String
  let isolated: Bool

  var draft: PassageDraft { PassageDraft(id: id, chapter: chapter, revision: revision, saveSeq: saveSeq, body: body, isolated: isolated) }
}

struct PassageRevisionFixture: Decodable {
  let draftId: String
  let revision: Int
  let body: String
}

struct PassageContextFixture: Decodable {
  let chapter: Int
  let draftId: String
  let revision: Int
  let saveSeq: Int
  let start: Int
  let end: Int
  let passageHash: String
  let quote: FixtureText
  let comment: FixtureText
  let firstParagraph: Int
  let lastParagraph: Int

  var context: ChatPassageContext {
    ChatPassageContext(
      chapter: chapter, draftId: draftId, revision: revision, saveSeq: saveSeq, start: start, end: end, passageHash: passageHash, quote: quote.value, comment: comment.value,
      firstParagraph: firstParagraph, lastParagraph: lastParagraph)
  }
}

struct ResolveExpectation: Decodable {
  let contexts: [PassageContextFixture]?
  let error: String?
  let chapter: Int?
}

struct ResolveCase: Decodable {
  let inputs: [PassageInputFixture]
  let drafts: [PassageDraftFixture]
  let revisions: [PassageRevisionFixture]
  let expected: ResolveExpectation
  let unrepresentable: Bool?
}

struct SpanFixture: Decodable {
  let start: Int
  let end: Int
}

struct RelocationCase: Decodable {
  let body: FixtureText
  let input: PassageInputFixture
  let earlier: FixtureText?
  let expected: SpanFixture?
}

struct ScreenFixture: Decodable {
  let text: FixtureText
  let scope: String
  let source: String
}

struct RenderCase: Decodable {
  let content: FixtureText
  let contexts: [PassageContextFixture]?
  let rendered: FixtureText
  let authorWords: FixtureText
  let screens: [ScreenFixture]
}

struct PassageFixture: Decodable {
  let resolves: [ResolveCase]
  let relocations: [RelocationCase]
  let render: [RenderCase]

  static func load() throws -> PassageFixture {
    try ReferenceFixture.decode(PassageFixture.self, from: "chat-policies/passage.json")
  }
}

func sameContext(_ left: ChatPassageContext, _ right: ChatPassageContext) -> Bool {
  left.chapter == right.chapter && left.draftId.jsEquals(right.draftId) && left.revision == right.revision && left.saveSeq == right.saveSeq && left.start == right.start
    && left.end == right.end && left.passageHash.jsEquals(right.passageHash) && left.quote.jsEquals(right.quote) && left.comment.jsEquals(right.comment)
    && left.firstParagraph == right.firstParagraph && left.lastParagraph == right.lastParagraph
}

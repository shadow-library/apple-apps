import ShadowText
import Testing

@testable import NovelForgeCore

private struct LocatedCase: Decodable {
  let body: String
  let anchor: PassageAnchor
  let freshness: String
  let start: Int?
  let end: Int?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    body = try container.decode(String.self)
    var packed = try container.nestedUnkeyedContainer()
    anchor = PassageAnchor(
      start: try packed.decode(Int.self),
      end: try packed.decode(Int.self),
      passageHash: try packed.decode(String.self),
      passage: try packed.decode(String.self),
      contextBefore: try packed.decode(String.self),
      contextAfter: try packed.decode(String.self)
    )
    var location = try container.nestedUnkeyedContainer()
    freshness = try location.decode(String.self)
    start = try location.decodeIfPresent(Int.self)
    end = try location.decodeIfPresent(Int.self)
  }

  var expected: PassageLocation {
    guard let start, let end else { return .stale }
    return freshness == "fresh" ? .fresh(start: start, end: end) : .relocated(start: start, end: end)
  }
}

private struct ContextCase: Decodable {
  let body: String
  let start: Int
  let end: Int
  let before: String
  let after: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    body = try container.decode(String.self)
    start = try container.decode(Int.self)
    end = try container.decode(Int.self)
    before = try container.decode(String.self)
    after = try container.decode(String.self)
  }
}

private struct AnchorFixture: Decodable {
  let located: [LocatedCase]
  let contexts: [ContextCase]
}

private struct HashCase: Decodable {
  let text: String
  let hash: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    hash = try container.decode(String.self)
  }
}

private struct FitCase: Decodable {
  let passage: String
  let replacement: String
  let result: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    passage = try container.decode(String.self)
    replacement = try container.decode(String.self)
    result = try container.decode(String.self)
  }
}

private struct ReplaceCase: Decodable {
  let body: String
  let start: Int
  let end: Int
  let replacement: String
  let result: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    body = try container.decode(String.self)
    start = try container.decode(Int.self)
    end = try container.decode(Int.self)
    replacement = try container.decode(String.self)
    result = try container.decode(String.self)
  }
}

private struct TextFixture: Decodable {
  let hashes: [HashCase]
  let fits: [FitCase]
  let replaces: [ReplaceCase]
}

struct PassageAnchorParityTests {
  private static func anchors() throws -> AnchorFixture {
    try ReferenceFixture.decode(AnchorFixture.self, from: "prose/anchor.json")
  }

  private static func texts() throws -> TextFixture {
    try ReferenceFixture.decode(TextFixture.self, from: "prose/anchor-text.json")
  }

  @Test func shouldCoverEveryFreshnessInTheFixture() throws {
    let located = try Self.anchors().located
    #expect(located.count >= 1000)
    for freshness in ["fresh", "relocated", "stale"] { #expect(located.contains { $0.freshness == freshness }) }
  }

  @Test func shouldLocateEveryReferencePassageAsTheReferenceDoes() throws {
    let mismatches = try Self.anchors().located.filter { locatePassage($0.body, anchor: $0.anchor) != $0.expected }
    #expect(mismatches.map(\.body) == [])
  }

  @Test func shouldTakeTheSameContextAsTheReference() throws {
    let mismatches = try Self.anchors().contexts.filter { reference in
      let context = anchorContext(reference.body, start: reference.start, end: reference.end)
      return !context.contextBefore.jsEquals(reference.before) || !context.contextAfter.jsEquals(reference.after)
    }
    #expect(mismatches.map(\.body) == [])
  }

  @Test func shouldHashEveryReferenceTextAsSha256OfItsUTF8() throws {
    let mismatches = try Self.texts().hashes.filter { passageHash($0.text) != $0.hash }
    #expect(mismatches.map(\.text) == [])
  }

  @Test func shouldFitEveryReplacementAsTheReferenceDoes() throws {
    let mismatches = try Self.texts().fits.filter { !fitReplacement($0.passage, $0.replacement).jsEquals($0.result) }
    #expect(mismatches.map(\.passage) == [])
  }

  @Test func shouldReplaceEveryPassageAsTheReferenceDoes() throws {
    let mismatches = try Self.texts().replaces.filter { !replacePassage($0.body, start: $0.start, end: $0.end, replacement: $0.replacement).jsEquals($0.result) }
    #expect(mismatches.map(\.body) == [])
  }
}

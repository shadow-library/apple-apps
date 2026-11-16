import Foundation
import Testing

@testable import NovelForgeCore

private struct ReferenceOutcome: Decodable {
  let reply: String
  let elements: [String]
  let state: String
  let dangling: Bool
}

private struct ReferenceChunking: Decodable {
  let name: String
  let cuts: [Int]
}

private struct ReferenceDocument: Decodable {
  let id: String
  let source: String
  let outcome: ReferenceOutcome
  let chunkings: [ReferenceChunking]
}

private struct ReferenceCase {
  let label: String
  let chunks: [[UInt16]]
  let outcome: ReferenceOutcome

  var expectedState: ReplyScanState? {
    switch outcome.state {
    case "awaitingReply": .awaitingReply
    case "replyFound": .replyFound
    case "completed": .completed
    default: nil
    }
  }

  var expectedReply: String {
    String(decoding: decodeHex(outcome.reply), as: UTF16.self) + (outcome.dangling ? "\u{FFFD}" : "")
  }
}

private func decodeHex(_ text: String) -> [UInt16] {
  let digits = Array(text.utf8)
  return stride(from: 0, to: digits.count - 3, by: 4).map { start in
    UInt16(String(decoding: digits[start..<start + 4], as: UTF8.self), radix: 16) ?? 0
  }
}

struct ReplyScannerParityTests {
  private static func loadDocuments() throws -> [ReferenceDocument] {
    try ReferenceFixture.decode([ReferenceDocument].self, from: "reply-scanner/cases.json")
  }

  private static func loadCases() throws -> [ReferenceCase] {
    try loadDocuments().flatMap { document in
      let source = decodeHex(document.source)
      return document.chunkings.map { chunking in
        let bounds = [0] + chunking.cuts + [source.count]
        let chunks = zip(bounds, bounds.dropFirst()).map { Array(source[$0..<$1]) }
        return ReferenceCase(label: "\(document.id) [\(chunking.name)]", chunks: chunks, outcome: document.outcome)
      }
    }
  }

  @Test func shouldCarryAtLeastFourHundredReferenceCases() throws {
    let documents = try Self.loadDocuments()
    #expect(try Self.loadCases().count >= 400)
    #expect(Set(documents.map { $0.id.split(separator: "-").dropLast().joined(separator: "-") }).count >= 12)
  }

  @Test func shouldMatchTheReferenceReplyOnEveryFixtureCase() throws {
    let mismatches = try Self.loadCases().filter { scan(chunks: $0.chunks).reply != $0.expectedReply }.map(\.label)
    #expect(mismatches.isEmpty, "reply differs for \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldMatchTheReferenceElementsOnEveryFixtureCase() throws {
    let mismatches = try Self.loadCases().filter { reference in
      let sources = scan(chunks: reference.chunks).elements.map(\.source)
      guard sources.count == reference.outcome.elements.count else { return true }
      return !zip(sources, reference.outcome.elements).allSatisfy { jsonEqual($0, $1) }
    }.map(\.label)
    #expect(mismatches.isEmpty, "elements differ for \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldMatchTheReferenceFinalStateOnEveryFixtureCase() throws {
    let mismatches = try Self.loadCases().filter { scan(chunks: $0.chunks).state != $0.expectedState }.map(\.label)
    #expect(mismatches.isEmpty, "state differs for \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldMatchTheReferenceOpOfEveryElement() throws {
    let mismatches = try Self.loadCases().filter { reference in
      let ops = scan(chunks: reference.chunks).elements.map(\.op)
      return ops != reference.outcome.elements.compactMap { JSONTree.parse($0)?.opString }
    }.map(\.label)
    #expect(mismatches.isEmpty, "op differs for \(mismatches.prefix(10)) of \(mismatches.count)")
  }
}

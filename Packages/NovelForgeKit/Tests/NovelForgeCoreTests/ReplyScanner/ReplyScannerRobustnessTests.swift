import Foundation
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let tokens = [
  "{", "}", "[", "]", ",", ":", "\"", "\\", "\\u", "\\ud83d", "\\ude00", "reply", "changeSet", "op", "\"reply\"", "\"changeSet\"", "\"op\"",
  "1", "-", "e", "0", "true", "null", " ", "\n",
  "\u{00A0}", "😀", "x", "{\"op\":\"a\"}", "\"reply\":\"r\"",
  "\"changeSet\":[",
]

private func assertWellBehaved(_ result: ScanResult, sourceLocation: SourceLocation = #_sourceLocation) {
  for element in result.elements {
    let parsed = try? JSONSerialization.jsonObject(with: Data(element.source.utf8))
    #expect((parsed as? [String: Any])?["op"] is String, "invalid element \(element.source)", sourceLocation: sourceLocation)
  }
}

private func randomChunks(_ units: [UInt16], _ generator: inout SeededGenerator) -> [[UInt16]] {
  split(units, sizes: (0..<max(units.count, 1)).map { _ in generator.int(in: 1...12) })
}

struct ReplyScannerRobustnessTests {
  @Test func shouldSurviveRandomBytesWithoutCrashingLoopingOrEmittingInvalidElements() throws {
    try forAll(iterations: 400, seed: 0xB17E) { generator in
      let text = String(decoding: generator.data(count: generator.int(in: 0...600)), as: UTF8.self)
      assertWellBehaved(scan(chunks: randomChunks(Array(text.utf16), &generator)))
    }
  }

  @Test func shouldSurviveRandomTokenSoupWithoutEmittingInvalidElements() throws {
    try forAll(iterations: 600, seed: 0x50F7) { generator in
      let text = (0..<generator.int(in: 0...120)).map { _ in generator.pick(from: tokens) }.joined()
      let result = scan(chunks: randomChunks(Array(text.utf16), &generator))
      assertWellBehaved(result)
      #expect(result == scan(text))
    }
  }

  @Test func shouldSurviveRandomTruncationsAndOnlyEverEmitAPrefixOfTheFullReply() throws {
    try forAll(iterations: 300, seed: 0x7C47) { generator in
      let reply = generator.unicodeString(maxLength: 40)
      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]), as: UTF8.self)
      let text = "{\"changeSet\":[{\"op\":\"a\",\"n\":[1,{\"x\":\"}]\"}]},{\"op\":\"b\"}],\"reply\":\(encoded)}"
      let units = Array(text.utf16)
      let full = scan(text)
      let cut = generator.int(in: 0...units.count)
      let truncated = scan(chunks: randomChunks(Array(units[..<cut]), &generator))
      assertWellBehaved(truncated)
      let danglingReplacement = truncated.reply.hasSuffix("\u{FFFD}") && full.reply.hasPrefix(String(truncated.reply.dropLast()))
      #expect(full.reply.hasPrefix(truncated.reply) || danglingReplacement)
      #expect(full.elements.starts(with: truncated.elements))
      #expect(cut == units.count || truncated.state != .completed)
    }
  }

  @Test func shouldHoldOnToNothingOnceTheObjectHasClosed() {
    var scanner = ReplyScanner()
    _ = scanner.consume(#"{"reply":"x"}"#)
    #expect(scanner.consume(String(repeating: "{\"reply\":\"y\"}", count: 1000)) == [])
    #expect(scanner.state == .completed)
  }

  @Test func shouldNotStackOverflowOnAnElementNestedOneHundredThousandLevelsDeep() {
    let depth = 100_000
    let element = #"{"op":"deep","v":"# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
    let result = scan(#"{"reply":"x","changeSet":["# + element + "]}")
    #expect(result.elements.count == 1)
    #expect(result.elements.first?.jsonValue == nil)
  }
}

import Foundation
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private struct GeneratedDocument {
  let text: String
  let reply: String
  let elements: [String]
}

private func encode(_ fragment: Any, escapingNonASCII generator: inout SeededGenerator) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: fragment, options: [.fragmentsAllowed, .withoutEscapingSlashes])
  var out = ""
  for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
    guard scalar.value > 0x7F, generator.chance(0.5) else {
      out.unicodeScalars.append(scalar)
      continue
    }
    for unit in String(scalar).utf16 { out += "\\u" + String(format: generator.chance(0.5) ? "%04x" : "%04X", unit) }
  }
  return out
}

private func randomValue(_ generator: inout SeededGenerator, depth: Int) -> Any {
  switch generator.int(in: 0...(depth > 0 ? 6 : 4)) {
  case 0: return generator.unicodeString(maxLength: 12)
  case 1: return generator.int(in: -1_000_000...1_000_000)
  case 2: return Double(generator.int(in: -4000...4000)) / 8
  case 3: return generator.chance(0.5)
  case 4: return NSNull()
  case 5: return (0..<generator.int(in: 0...3)).map { _ in randomValue(&generator, depth: depth - 1) }
  default: return randomObject(&generator, depth: depth - 1)
  }
}

private func randomObject(_ generator: inout SeededGenerator, depth: Int, op: String? = nil) -> [String: Any] {
  var object: [String: Any] = [:]
  for index in 0..<generator.int(in: 0...3) { object["k\(index)"] = randomValue(&generator, depth: depth) }
  if let op { object["op"] = op }
  return object
}

private func padding(_ generator: inout SeededGenerator) -> String {
  generator.pick(from: ["", "", " ", "\n", "\t ", "\r\n  "])
}

private func generateDocument(_ generator: inout SeededGenerator) throws -> GeneratedDocument {
  // Foundation's decoder drops a leading U+FEFF from a decoded string, so the oracle cannot judge a reply that starts with one.
  let generated = generator.unicodeString(maxLength: 60)
  let reply = generated.unicodeScalars.first == "\u{FEFF}" ? "x" + generated : generated
  let elementObjects = (0..<generator.int(in: 0...4)).map { _ in randomObject(&generator, depth: 3, op: generator.asciiString(maxLength: 10)) }
  let elementTexts = try elementObjects.map { try encode($0, escapingNonASCII: &generator) }
  var members: [String] = [
    "\"reply\"\(padding(&generator)):\(padding(&generator))\(try encode(reply, escapingNonASCII: &generator))",
    "\"changeSet\"\(padding(&generator)):\(padding(&generator))[" + elementTexts.map { padding(&generator) + $0 + padding(&generator) }.joined(separator: ",") + "]",
  ]
  for index in 0..<generator.int(in: 0...3) {
    members.append("\"extra\(index)\":" + (try encode(randomValue(&generator, depth: 3), escapingNonASCII: &generator)))
  }
  let ordered = generator.shuffled(members)
  let text = "{" + ordered.map { padding(&generator) + $0 + padding(&generator) }.joined(separator: ",") + "}"
  return GeneratedDocument(text: text, reply: reply, elements: elementTexts)
}

private func randomSizes(_ generator: inout SeededGenerator, count: Int, upTo limit: Int) -> [Int] {
  (0..<count).map { _ in generator.int(in: 1...limit) }
}

struct ReplyScannerPropertyTests {
  @Test func shouldMatchWhatJSONSerializationDecodesForAnyValidDocumentAndAnyChunking() throws {
    try forAll(iterations: 250, seed: 0xD04) { generator in
      let document = try generateDocument(&generator)
      let decoded = try #require(JSONSerialization.jsonObject(with: Data(document.text.utf8)) as? [String: Any])
      let decodedElements = try #require(decoded["changeSet"] as? [Any])
      let length = document.text.utf16.count

      let whole = scan(document.text)
      let units = scan(document.text, sizes: Array(repeating: 1, count: length))
      let random = scan(document.text, sizes: randomSizes(&generator, count: length, upTo: 9))

      #expect(whole.reply == (decoded["reply"] as? String))
      #expect(whole.state == .completed)
      #expect(whole.elements.count == decodedElements.count)
      for (element, expected) in zip(whole.elements, decodedElements) {
        let parsed = try JSONSerialization.jsonObject(with: Data(element.source.utf8))
        #expect((parsed as AnyObject).isEqual(expected))
      }
      #expect(whole == units)
      #expect(whole == random)
    }
  }
}

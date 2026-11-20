import ShadowText
import Testing

@testable import NovelForgeCore

private let harbourNote = "The [withheld] was empty and the harbour keeper knew it."

private struct DenseCorpus {
  private static let words = [
    "harbour", "keeper", "lamp", "tide", "court", "bell", "ledger", "forgery", "heir", "twin", "Mara", "Elias", "Tobin", "Amara", "salt", "drowned", "crown", "veil",
    "pledge", "debt", "study", "door", "well", "ash", "storm", "gate", "river", "north", "song", "mirror", "blood", "oath", "silver", "ring", "letter", "map", "key",
  ]
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func index(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(bound))
  }

  mutating func phrase(_ count: Int) -> String {
    (0..<count).map { _ in Self.words[index(Self.words.count)] }.joined(separator: " ")
  }

  mutating func facts(_ count: Int) -> [DisclosureFact] {
    (0..<count).map { factIndex in
      let terms = (0..<3).map { _ in phrase(1 + index(3)) }
      let text = (0..<(1 + index(3))).map { _ in phrase(4 + index(10)) + "." }.joined(separator: " ")
      return DisclosureFact(factKey: "secret_\(factIndex)", text: text, terms: terms, source: .manual, revealChapter: 99)
    }
  }

  /// A page that names the facts' terms and keys, copies some of their texts and, when `pasting`, quotes a writer pack's marker-bearing note.
  mutating func page(_ facts: [DisclosureFact], mentions: Int, pasting note: String? = nil) -> String {
    var parts: [String] = []
    for _ in 0..<mentions {
      let fact = facts[index(facts.count)]
      let terms = fact.terms ?? []
      parts.append("Then \(terms[index(terms.count)]) came up, see fact:\(fact.factKey).")
      if index(3) == 0 { parts.append(fact.text) }
      if let note, index(8) == 0 { parts.append(note) }
      parts.append(phrase(6) + ".")
    }
    return parts.joined(separator: " ")
  }
}

private func policy(_ facts: [DisclosureFact]) throws -> WriterDisclosurePolicy {
  try WriterDisclosurePolicy(WriterDisclosureInput(chapter: 3, lockedFacts: facts, plannerOnly: [], plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
}

private func occurrences(of needle: String, in text: String) -> [Range<Int>] {
  let units = text.jsCodeUnits
  let needleUnits = needle.jsCodeUnits
  var found: [Range<Int>] = []
  var at = JSText.indexOf(needleUnits, in: units, from: 0)
  while at != -1 {
    found.append(at..<(at + needleUnits.count))
    at = JSText.indexOf(needleUnits, in: units, from: at + 1)
  }
  return found
}

@Suite("Order search cost on dense pages")
struct WithholdingCostTests {
  @Test(
    "should withhold a constraint note that quotes a marker only where its pieces match, leaving the rest of a dense page as it is without the note",
    arguments: [(UInt64(1), 40), (2, 40), (3, 200)])
  func shouldBoundMarkerNotes(seed: UInt64, mentions: Int) throws {
    var corpus = DenseCorpus(seed: seed)
    let facts = corpus.facts(10)
    var noted = facts
    noted[0].constraintNote = harbourNote
    let page = corpus.page(facts, mentions: mentions, pasting: harbourNote)
    let quoted = occurrences(of: String(harbourNote.dropLast()), in: page)
    #expect(!quoted.isEmpty)
    let withNote = try policy(noted).withholding(page, .biblePage)
    let withoutNote = try policy(facts).withholding(page, .biblePage)
    #expect(withNote.exhaustedComponents == 0)
    for offset in withNote.hidden.indices where withNote.hidden[offset] != withoutNote.hidden[offset] {
      #expect(quoted.contains { $0.contains(offset) }, "unit \(offset) changed outside the quoted note")
    }
    for range in quoted { #expect(range.allSatisfy { withNote.hidden[$0] }) }
  }

  /// Counted, not timed: a search that spread back over the whole page would need thousands of states and windows as wide as the page.
  @Test("should keep the order search on a dense page of a small vocabulary within a fixed cost", arguments: [40, 80])
  func shouldStayWithinSearchCost(factCount: Int) throws {
    var corpus = DenseCorpus(seed: 1)
    var facts = corpus.facts(factCount)
    facts[0].constraintNote = harbourNote
    let page = corpus.page(facts, mentions: 200, pasting: harbourNote)
    #expect(page.jsLength > 20_000)
    let outcome = try policy(facts).withholding(page, .biblePage)
    #expect(outcome.exhaustedComponents == 0)
    #expect(outcome.searchCost.states > 0)
    #expect(outcome.searchCost.states <= 1_000)
    #expect(outcome.searchCost.scannedUnits <= 100_000)
    #expect(outcome.searchCost.largestWindow <= 1_000)
  }
}

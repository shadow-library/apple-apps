import Testing

@testable import NovelForgeCore

private func policyInput(_ row: OrderedJSON) -> WriterDisclosureInput {
  WriterDisclosureInput(
    chapter: row.at(0).intValue, lockedFacts: row.at(1).items.map(fixtureFact), plannerOnly: row.at(2).strings ?? [], plannerPages: row.at(3).strings ?? [], volumeOrdinals: [:],
    currentVolumeOrdinal: nil)
}

@Suite("Withholdings in every order the reference could take")
struct WithholdingOrderTests {
  @Test("should withhold every code unit some order of tied withholdings withholds, and keep the reference's text when every order agrees")
  func shouldCoverEveryOrder() throws {
    let cases = try DisclosureFixture.cases("orders.json", "orderCases")
    #expect(cases.count > 50)
    var disagreeing = 0
    for row in cases {
      let text = row.at(1).stringValue ?? ""
      let field = try #require(WriterField(rawValue: row.at(2).stringValue ?? ""))
      var policy = try WriterDisclosurePolicy(policyInput(row.at(0)))
      let outcome = policy.withholding(text, field)
      for span in row.at(5).items {
        for offset in (span.at(0).intValue ?? 0)..<(span.at(1).intValue ?? 0) {
          #expect(outcome.hidden.indices.contains(offset) && outcome.hidden[offset], "unit \(offset) of \(text.debugDescription) is shown, some order withholds it")
        }
      }
      let outputs = row.at(4).strings ?? []
      if outputs.count == 1 {
        #expect(outcome.text.jsEquals(outputs[0]), "\(text.debugDescription)")
      } else {
        disagreeing += 1
        #expect(outcome.text.jsEquals(markedText(text, hidden: outcome.hidden)), "\(text.debugDescription)")
      }
      #expect(try policy.scrub(text, field).jsEquals(outcome.text))
    }
    #expect(disagreeing > 10)
  }

  @Test("should withhold both nouns where the reference's two orders each show one")
  func shouldWithholdOverlappingTies() throws {
    var policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(
        chapter: 3, lockedFacts: [DisclosureFact(factKey: "B_y", text: "", terms: ["fox den"]), DisclosureFact(factKey: "a_x", text: "", terms: ["red fox"])], plannerOnly: [],
        plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
    #expect(try policy.scrub("The red fox den was empty.", .prose) == "The [withheld] was empty.")
  }

  @Test("should let an order spend a tied pattern while it matches nothing, so a later pattern still sees the text it would have taken")
  func shouldSpendIdlePatterns() throws {
    let first = try withholding(#"a"#, weight: 5)
    let afterMarker = try withholding(#"(?<=\])b"#, weight: 5)
    let later = try withholding(#"bc"#, weight: 1)
    let outcome = applyWithholdings([first, afterMarker, later], to: "abc")
    #expect(outcome.hidden == [true, true, true])
    #expect(outcome.text == "[withheld]")
  }

  @Test("should let a repeated pattern move to any weight it could have kept")
  func shouldMoveRepeatedPatterns() throws {
    let heavier = try withholding(#"b"#, weight: 6)
    var lighter = try withholding(#"ab"#, weight: 5)
    lighter.possibleWeights = 5...7
    let outcome = applyWithholdings([heavier, lighter], to: "ab")
    #expect(outcome.hidden == [true, true])
  }

  @Test("should withhold every stretch a component could reach when its orders are too many to search, and only that component")
  func shouldFailClosedPerComponent() throws {
    let facts = [
      DisclosureFact(factKey: "B_y", text: "", terms: ["fox den"]), DisclosureFact(factKey: "a_x", text: "", terms: ["red fox"]),
      DisclosureFact(factKey: "lamp", text: "", terms: ["lamp oil"]),
    ]
    let policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(chapter: 3, lockedFacts: facts, plannerOnly: [], plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
    let outcome = applyWithholdings(policy.withholdings, to: "The red fox den was empty; lamp oil burned.", budget: 1)
    #expect(outcome.exhaustedComponents == 1)
    #expect(outcome.text == "The [withheld] was empty; [withheld] burned.")
  }

  @Test("should search no order on long pages that copy the canon of many locked facts, nor on a long chapter")
  func shouldNotFailClosedOnLongPages() throws {
    var generator = SeededWords(seed: 15)
    for factCount in [10, 25, 40] {
      let facts = (0..<factCount).map { index in
        DisclosureFact(
          factKey: "fact_\(index)", text: generator.sentences(2), constraintNote: generator.sentences(1), terms: [generator.word(), generator.word() + " " + generator.word()])
      }
      var page = ""
      while page.utf16.count < 5_000 {
        let fact = facts[generator.index(facts.count)]
        page += [fact.text, "See fact:\(fact.factKey).", fact.terms?.first ?? "", generator.sentences(1)][generator.index(4)] + (generator.index(4) == 0 ? "\n\n" : " ")
      }
      let policy = try WriterDisclosurePolicy(
        WriterDisclosureInput(chapter: 9, lockedFacts: facts, plannerOnly: [generator.sentences(2)], plannerPages: [page], volumeOrdinals: [:], currentVolumeOrdinal: nil))
      #expect(policy.withholding(page, .biblePage).exhaustedComponents == 0, "\(factCount) facts")
    }
    let facts = (0..<12).map { DisclosureFact(factKey: "fact_\($0)", text: generator.sentences(3), terms: [generator.word()]) }
    var chapter = ""
    while chapter.utf16.count < 20_000 { chapter += generator.sentences(1) + (generator.index(5) == 0 ? "\n\n" : " ") }
    let policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(chapter: 9, lockedFacts: facts, plannerOnly: [], plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
    #expect(policy.withholding(chapter + facts[3].text, .prose).exhaustedComponents == 0)
  }

  @Test("should withhold the whole of a chain only one order completes")
  func shouldCoverChainedOrder() throws {
    let facts = [("f1", "ab cde"), ("f2", "-xy zw"), ("f3", "cde-xy")].map { DisclosureFact(factKey: $0.0, text: "", terms: [$0.1]) }
    var policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(chapter: 4, lockedFacts: facts, plannerOnly: [], plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
    #expect(try policy.scrub("ab cde-xy zw", .prose) == "[withheld]")
  }

  @Test("should treat a pattern repeated with different spacing as able to sit at any of its weights")
  func shouldWidenRepeatedPatterns() throws {
    let pages = ["Mara walks the long harbour wall.", "Mara  walks the long harbour\nwall!"]
    let policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(chapter: 4, lockedFacts: [], plannerOnly: [], plannerPages: pages, volumeOrdinals: [:], currentVolumeOrdinal: nil))
    #expect(policy.withholdings.contains { $0.possibleWeights == 32...33 })
  }
}

private func withholding(_ source: String, weight: Int) throws -> Withholding {
  Withholding(pattern: try JSRegex(source, flags: "gu"), weight: weight, copyFieldsOnly: false)
}

private func markedText(_ text: String, hidden: [Bool]) -> String {
  var units: [UInt16] = []
  for (index, unit) in text.utf16.enumerated() {
    if !hidden[index] {
      units.append(unit)
    } else if index == 0 || !hidden[index - 1] {
      units += Array("[withheld]".utf16)
    }
  }
  return JSText.string(fromCodeUnits: units)
}

private struct SeededWords {
  private static let vocabulary = ["the", "ledger", "keeper", "harbour", "lamp", "tides", "court", "bells", "Mara", "drowned", "walks", "slowly", "under", "grey", "rains"]
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func index(_ count: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int(state >> 33) % count
  }

  mutating func word() -> String {
    Self.vocabulary[index(Self.vocabulary.count)]
  }

  mutating func sentences(_ count: Int) -> String {
    (0..<count).map { _ in (0..<(4 + index(8))).map { _ in word() }.joined(separator: " ") + "." }.joined(separator: " ")
  }
}

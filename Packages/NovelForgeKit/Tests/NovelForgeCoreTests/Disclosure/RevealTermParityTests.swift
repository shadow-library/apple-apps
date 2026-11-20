import ShadowText
import Testing

@testable import NovelForgeCore

@Suite("Reveal terms, leak scan and renderers against the reference")
struct RevealTermParityTests {
  @Test("should build every give-away term pattern and match it as bun does")
  func shouldBuildTermPatterns() throws {
    let cases = try DisclosureFixture.cases("terms.json", "termCases")
    #expect(cases.count > 100)
    for row in cases {
      let term = row.at(0).stringValue ?? ""
      let pattern = try revealTermPattern(term, global: row.at(1).bool)
      #expect(sameText(pattern?.source, row.at(2).stringValue), "source of \(term)")
      #expect(sameText(pattern?.flags, row.at(3).stringValue), "flags of \(term)")
      for probe in row.at(4).items {
        let text = probe.at(0).stringValue ?? ""
        let match = pattern?.exec(text)
        let expected = probe.at(1)
        #expect(match?.index == expected.at(0).intValue && match?.length == expected.at(1).intValue, "\(term) in \(text.debugDescription)")
      }
    }
  }

  @Test("should name clues by the same rule and re-judge only a changed write")
  func shouldNameClues() throws {
    for row in try DisclosureFixture.cases("terms.json", "clueCases") {
      let clues = row.at(0).strings
      let terms = row.at(1).strings
      #expect(sameTexts(try cluesNamingTerms(clues, terms), row.at(2).strings ?? []))
      let before = row.at(3).objectValue.map { ClueTermFields(allowedClues: $0["allowedClues"]?.strings, terms: $0["terms"]?.strings) }
      #expect(sameTexts(try changedCluesNamingTerms(before: before, after: ClueTermFields(allowedClues: clues, terms: terms)), row.at(4).strings ?? []))
    }
  }

  @Test("should treat only a reveal chapter at or before the first as open canon")
  func shouldDetectOpenCanon() throws {
    for row in try DisclosureFixture.cases("terms.json", "openCanonCases") {
      #expect(isOpenCanon(row.at(0).intValue) == row.at(1).bool)
    }
  }

  @Test("should scan leaks with excerpts and reduce findings to writer-safe lines")
  func shouldScanLeaks() throws {
    let cases = try DisclosureFixture.cases("terms.json", "leakCases")
    #expect(cases.count > 50)
    for row in cases {
      let facts = row.at(0).items.map(fixtureFact)
      let body = row.at(1).stringValue ?? ""
      let issues = try scanKnowledgeLeaks(body, hidden: facts)
      let expected = row.at(2).items
      #expect(issues.count == expected.count)
      for (issue, reference) in zip(issues, expected) {
        #expect(issue.factKey.jsEquals(reference.at(0).stringValue ?? ""))
        #expect(issue.term.jsEquals(reference.at(1).stringValue ?? ""))
        #expect(issue.excerpt.jsEquals(reference.at(2).encodedString), "excerpt in \(body.debugDescription)")
      }
      let prescan = row.at(3).items.map { PrescanLeak(factKey: $0.at(0).stringValue ?? "", term: $0.at(1).stringValue ?? "") }
      #expect(sameTexts(writerSafeLeakLines(prescan: prescan, judgeIssues: row.at(4).strings ?? [], forbidden: facts), row.at(5).strings ?? []))
    }
  }

  @Test("should split and render facts as the reference does")
  func shouldRender() throws {
    for row in try DisclosureFixture.cases("terms.json", "renderCases") {
      let facts = row.at(0).items.map(fixtureFact)
      let pov = row.at(1).items.map { PovMember(entityKey: $0.at(0).stringValue ?? "", name: $0.at(1).stringValue ?? "") }
      let split = splitKnowledgeView(facts, knownKeys: Set((row.at(2).strings ?? []).map { JSString($0) }), learnKeys: Set((row.at(3).strings ?? []).map { JSString($0) }))
      let keys = { (list: [DisclosureFact]) in list.map(\.factKey) }
      #expect(sameTexts(keys(split.known), row.at(4).at(0).strings ?? []))
      #expect(sameTexts(keys(split.reveals), row.at(4).at(1).strings ?? []))
      #expect(sameTexts(keys(split.hidden), row.at(4).at(2).strings ?? []))
      #expect(renderReaderKnows(facts, pov: pov).jsEquals(row.at(5).stringValue ?? ""))
      #expect(renderJudgeReaderKnows(facts).jsEquals(row.at(6).stringValue ?? ""))
      #expect(renderKnownFacts(facts).jsEquals(row.at(7).stringValue ?? ""))
      #expect(renderChapterReveals(facts).jsEquals(row.at(8).stringValue ?? ""))
      #expect(renderHiddenConstraints(facts).jsEquals(row.at(9).stringValue ?? ""))
      #expect(sameTexts(keys(withWriterNotes(facts)), row.at(10).strings ?? []))
      #expect(renderForbiddenFacts(facts).jsEquals(row.at(11).stringValue ?? ""))
    }
  }
}

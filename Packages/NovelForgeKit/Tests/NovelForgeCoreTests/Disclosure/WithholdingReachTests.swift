import Testing

@testable import NovelForgeCore

private func reach(ofTerm term: String) throws -> WithholdingReach? {
  let policy = try WriterDisclosurePolicy(
    WriterDisclosureInput(
      chapter: 3, lockedFacts: [DisclosureFact(factKey: "k", text: "", terms: [term])], plannerOnly: [], plannerPages: [], volumeOrdinals: [:], currentVolumeOrdinal: nil))
  return try #require(policy.withholdings.first { $0.weight == term.jsLength }).reach
}

private func pieces(ofTerm term: String) throws -> [JSRegex]? {
  guard case .markers(let pieces)? = try reach(ofTerm: term) else { return nil }
  return pieces
}

@Suite("Where a withholding can match")
struct WithholdingReachTests {
  @Test("should bound a body that cannot take marker text by its own matches")
  func shouldBoundPlainBodies() throws {
    for term in ["red fox", "a[b", "x]y", "the"] {
      guard case .body(let body, let rewritesMarkers)? = try reach(ofTerm: term) else {
        Issue.record("\(term) has no body reach")
        continue
      }
      #expect(body.test(term))
      #expect(!rewritesMarkers, "\(term)")
    }
  }

  @Test("should mark a body spelt like a marker's letters as able to rewrite marker text")
  func shouldMarkMarkerLetters() throws {
    for term in ["withheld", "held", "WITH", "ithhe"] {
      guard case .body(_, let rewritesMarkers)? = try reach(ofTerm: term) else {
        Issue.record("\(term) has no body reach")
        continue
      }
      #expect(rewritesMarkers, "\(term)")
    }
  }

  @Test("should cut a body that can take marker text into the pieces it must match before scrubbing")
  func shouldCutMarkerBodies() throws {
    let note = try #require(try pieces(ofTerm: "The [withheld] was empty"))
    #expect(note.count == 2)
    #expect(note.first?.test("The ") == true && note.first?.test("The") == false)
    #expect(note.last?.test(" was empty") == true)
    #expect(try pieces(ofTerm: "keeper [withheld")?.count == 1)
    #expect(try pieces(ofTerm: "keeper [with")?.count == 1)
    #expect(try pieces(ofTerm: "withheld] den")?.count == 1)
    #expect(try pieces(ofTerm: "[WITHHELD]")?.isEmpty == true)
    #expect(try pieces(ofTerm: "d] [w")?.isEmpty == false)
  }

  @Test("should cut a passage that quotes a marker at its words and leave the emphasis between them to the pieces")
  func shouldCutMarkerPassages() throws {
    let policy = try WriterDisclosurePolicy(
      WriterDisclosureInput(
        chapter: 3, lockedFacts: [DisclosureFact(factKey: "k", text: "", constraintNote: "The [withheld] was *empty*.")], plannerOnly: [], plannerPages: [],
        volumeOrdinals: [:], currentVolumeOrdinal: nil))
    let note = try #require(policy.withholdings.first { $0.weight == "The [withheld] was empty".jsLength })
    guard case .markers(let pieces)? = note.reach else {
      Issue.record("the note has no marker reach")
      return
    }
    #expect(pieces.count == 2)
    #expect(pieces.last?.test("  _was_ empty") == true)
  }

  @Test("should not know the reach of a pattern its body does not spell")
  func shouldRefuseForeignPatterns() throws {
    let pattern = try JSRegex(#"(?<![\p{L}\p{N}_])red fox(?![\p{L}\p{N}_])"#, flags: "giu")
    #expect(WithholdingReach(pattern: pattern, body: [.character("r", source: "r")]) == nil)
    #expect(Withholding(pattern: pattern, weight: 7, copyFieldsOnly: false).reach == nil)
  }
}

import Testing

@testable import NovelForgeCore

private let openedProbes: [Int?] = [nil, -1, 0, 1, 4, 5, 6, 12]

private func policyInput(_ row: OrderedJSON) -> WriterDisclosureInput {
  var ordinals: [JSString: Int] = [:]
  for pair in row.at(4).items { ordinals[JSString(pair.at(0).stringValue ?? "")] = pair.at(1).intValue }
  return WriterDisclosureInput(
    chapter: row.at(0).intValue, lockedFacts: row.at(1).items.map(fixtureFact), plannerOnly: row.at(2).strings ?? [], plannerPages: row.at(3).strings ?? [],
    volumeOrdinals: ordinals, currentVolumeOrdinal: row.at(5).intValue)
}

/// Expects the reference's text, or the reference's throw (its call stack ending a leak-finding cycle) as `.leakFindingCycle`.
private func expectOutcome(_ expected: OrderedJSON, _ context: String, _ run: () throws(DisclosureError) -> OrderedJSON) -> Bool {
  do {
    let actual = try run()
    #expect(!expected.throwsMarker, "the reference threw on \(context)")
    #expect(actual == expected, "\(context)")
  } catch {
    #expect(error == .leakFindingCycle)
    #expect(expected.throwsMarker, "Swift threw on \(context)")
    return true
  }
  return false
}

@Suite("Writer disclosure policy against the reference")
struct WriterDisclosurePolicyParityTests {
  @Test("should withhold, resolve and rewrite exactly as the reference policy does")
  func shouldMatchReference() throws {
    let cases = try DisclosureFixture.cases("policy.json", "policyCases")
    #expect(cases.count > 100)
    var cycles = 0
    for row in cases {
      var policy = row.at(0) == .null ? WriterDisclosurePolicy.planner : try WriterDisclosurePolicy(policyInput(row.at(0)))
      let out = row.at(1)
      #expect(policy.withholdings.count == out.at(0).at(0).intValue)
      #expect(withholdingDigest(policy) == out.at(0).at(1).stringValue)
      var threw = false
      for scrub in out.at(1).items {
        let text = scrub.at(0).stringValue ?? ""
        let field = try #require(WriterField(rawValue: scrub.at(1).stringValue ?? ""))
        threw = expectOutcome(scrub.at(2), "scrub \(text.debugDescription) as \(field)") { () throws(DisclosureError) in .string(try policy.scrub(text, field)) } || threw
      }
      for state in out.at(2).items {
        let max = state.at(1).intValue ?? 0
        threw = expectOutcome(state.at(2), "state \(state.at(0))") { () throws(DisclosureError) in try policy.scrubState(state.at(0), establishedFactsMax: max) } || threw
      }
      for ref in out.at(3).items {
        let text = ref.at(0).stringValue ?? ""
        #expect(policy.canResolve(text) == ref.at(1).bool, "canResolve \(text.debugDescription)")
      }
      #expect(openedProbes.map(policy.opensBy) == out.at(4).items.map(\.bool))
      #expect(sameTexts(try policy.allowedClues(), out.at(5).strings ?? []))
      for body in out.at(6).items {
        threw =
          expectOutcome(body.at(1), "leak lines of \(body.at(0))") { () throws(DisclosureError) in
            .array(try policy.leakLines(body.at(0).stringValue ?? "").map(OrderedJSON.string))
          } || threw
      }
      for line in out.at(7).items {
        threw = expectOutcome(line.at(1), "leak line \(line.at(0))") { () throws(DisclosureError) in .string(try policy.scrubLeakLine(line.at(0).stringValue ?? "")) } || threw
      }
      if let messages = out.at(8).strings {
        threw = expectOutcome(out.at(9), "system messages") { () throws(DisclosureError) in .array(try policy.scrubSystemMessages(messages).map(OrderedJSON.string)) } || threw
      }
      if threw {
        cycles += 1
        continue
      }
      let counts = out.at(10).items.map { "\($0.at(0).stringValue ?? "")=\($0.at(1).intValue ?? 0)" }
      #expect(policy.withheld.map { "\($0.field.rawValue)=\($0.count)" } == counts)
    }
    #expect(cycles > 0)
  }
}

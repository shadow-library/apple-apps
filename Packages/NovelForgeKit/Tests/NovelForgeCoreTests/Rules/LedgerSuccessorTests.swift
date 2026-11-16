import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private func previous(_ overrides: (inout SupersededLedgerEntry) -> Void = { _ in }) -> SupersededLedgerEntry {
  var entry = SupersededLedgerEntry(
    kind: .decision,
    why: "It is the question under every chapter of the ferry route.",
    writerLine: "Every chapter tests one promise.",
    rejectedAlternatives: ["Can a town forgive a flood?"],
    payload: ["drivers": ["slice_of_life"]],
    links: ["bibleDocuments": [["section": "project", "slug": "theme"]]],
    stepKey: nil,
    ideaId: nil,
    rejectionScope: nil,
    rejectionAnchor: nil
  )
  overrides(&entry)
  return entry
}

private func supersession(kind: AuthorSupersedeKind? = nil, statement: String = "Reworded theme", why: String? = nil, writerLine: String? = nil) -> AuthorSupersession {
  AuthorSupersession(kind: kind, statement: statement, why: why, writerLine: writerLine, rejectedAlternatives: nil, payload: nil)
}

private func known<Value: RawRepresentable>(_ value: JSONValue?, _ type: Value.Type) throws -> Value? where Value.RawValue == String {
  guard let name = try value?.optionalString() else { return nil }
  return try Value(rawValue: name).orThrow("\(type) value \(name)")
}

private func entry(_ row: JSONValue) throws -> SupersededLedgerEntry {
  SupersededLedgerEntry(
    kind: try LedgerEntryKind(rawValue: try row["kind"].orThrow("kind").string()).orThrow("kind"),
    why: try row["why"]?.optionalString(),
    writerLine: try row["writerLine"]?.optionalString(),
    rejectedAlternatives: try row["rejectedAlternatives"].orThrow("alternatives").list().strings(),
    payload: row["payload"],
    links: try row["links"].orThrow("links"),
    stepKey: try row["stepKey"]?.optionalString(),
    ideaId: try row["ideaId"]?.optionalString(),
    rejectionScope: try known(row["rejectionScope"], LedgerRejectionScope.self),
    rejectionAnchor: row["rejectionAnchor"]
  )
}

private func supersession(_ row: JSONValue) throws -> AuthorSupersession {
  AuthorSupersession(
    kind: try known(row["kind"], AuthorSupersedeKind.self),
    statement: try row["statement"].orThrow("statement").string(),
    why: try row["why"]?.optionalString(),
    writerLine: try row["writerLine"]?.optionalString(),
    rejectedAlternatives: try row["ra"]?.list().strings() ?? row["rejectedAlternatives"]?.list().strings(),
    payload: row["payload"]
  )
}

private func matches(_ result: SupersedingEntry, _ expected: JSONValue, statement: String) throws -> Bool {
  let idea = expected["idea"]
  let ideaMatches =
    try idea.map {
      result.idea
        == LedgerIdeaRejection(
          ideaId: try $0["ideaId"].orThrow("ideaId").string(), scope: try LedgerRejectionScope(rawValue: try $0["scope"].orThrow("scope").string()).orThrow("scope"),
          anchor: $0["anchor"]?.isNull == true ? nil : $0["anchor"])
    } ?? (result.idea == nil)
  return try result.kind.rawValue == expected["kind"].orThrow("kind").string() && result.decidedBy == .author && result.statement == statement
    && result.why == expected["why"]?.optionalString()
    && result.writerLine == expected["writerLine"]?.optionalString() && result.rejectedAlternatives == (expected["ra"].orThrow("ra").list().strings())
    && result.payload == expected["payload"]
    && result.links == expected["links"].orThrow("links") && result.stepKey == expected["stepKey"]?.optionalString() && ideaMatches
}

struct LedgerSuccessorParityTests {
  @Test func shouldMatchTheReferenceSuccessorOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("ledger", "successor")
    #expect(cases.count >= 300)
    let outcomes = try cases.map { try $0.at(2) }
    #expect(outcomes.contains { $0["error"] != nil } && outcomes.contains { $0["idea"] != nil })
    let failed = try mismatches(cases) { row in
      let input = try supersession(try row.at(1))
      let expected = try row.at(2)
      do {
        let result = try authorSuccessor(try entry(try row.at(0)), input)
        return try matches(result, expected, statement: input.statement)
      } catch let error as LedgerRuleError {
        return try expected["error"]?.string() == error.code
      }
    }
    #expect(failed.isEmpty, "successor differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceStatusOfEveryRetirementShape() throws {
    for row in try RuleFixture.section("ledger", "status") {
      let status = ledgerEntryStatus(supersededAt: try row.at(0).bool() ? Date(timeIntervalSince1970: 1) : nil, withdrawnReason: try row.at(1).optionalString())
      #expect(status.rawValue == (try row.at(2).string()))
    }
  }

  @Test func shouldWordTheRefusalAsTheReferenceDoes() throws {
    let message = try RuleFixture.load("ledger")["message"].orThrow("message").string()
    #expect(LedgerRuleError.onlyDecisionOrSystemDetailBecomesDecision.errorDescription == message)
    #expect(LedgerRuleError.onlyDecisionOrSystemDetailBecomesDecision.code == "LDG_003")
  }
}

struct LedgerSuccessorSpecTests {
  @Test func shouldKeepWhyWriterLineAlternativesPayloadAndLinksWhenADecisionIsReworded() throws {
    let before = previous()
    let next = try authorSuccessor(before, supersession())
    #expect(next.kind == .decision && next.decidedBy == .author && next.statement == "Reworded theme")
    #expect(next.why == before.why && next.writerLine == before.writerLine && next.links == before.links)
    #expect(next.rejectedAlternatives == before.rejectedAlternatives && next.payload == before.payload)
  }

  @Test func shouldClearATextFieldSentAsAnEmptyString() throws {
    let clearedLine = try authorSuccessor(previous(), supersession(writerLine: ""))
    let clearedWhy = try authorSuccessor(previous(), supersession(why: "  "))
    #expect(clearedLine.writerLine == nil && clearedWhy.why == nil)
  }

  @Test func shouldTrimAReplacedTextFieldButLeaveTheStatementAsGiven() throws {
    let next = try authorSuccessor(previous(), supersession(statement: " keep ", why: " new "))
    #expect(next.why == "new" && next.statement == " keep ")
  }

  @Test func shouldTurnAnOverruledSystemDetailIntoAnAuthorDecision() throws {
    let next = try authorSuccessor(previous { $0.kind = .system }, supersession())
    #expect(next.kind == .decision && next.decidedBy == .author)
    #expect(next.why != nil)
  }

  @Test func shouldRefuseToTurnADirectionIntoADecision() {
    #expect(throws: LedgerRuleError.onlyDecisionOrSystemDetailBecomesDecision) {
      try authorSuccessor(previous { $0.kind = .direction }, supersession(kind: .decision))
    }
  }

  @Test func shouldCarryNothingOverWhenTheKindChanges() throws {
    let next = try authorSuccessor(previous(), supersession(kind: .rejected))
    #expect(next.why == nil && next.writerLine == nil && next.payload == nil && next.links == .object([:]) && next.rejectedAlternatives.isEmpty)
  }

  @Test func shouldKeepATurnedDownIdeaAndItsScopeWhenTheAuthorRewordsTheRejectionAndDropThemWhenItBecomesADirection() throws {
    let turnedDown = previous {
      $0.kind = .rejected
      $0.ideaId = "abc"
      $0.rejectionScope = .notNow
      $0.rejectionAnchor = ["volumeKey": "volume_1"]
    }
    let reworded = try authorSuccessor(turnedDown, supersession(statement: "No rival for the keeper"))
    let redirected = try authorSuccessor(turnedDown, supersession(kind: .direction, statement: "A rival, later"))
    #expect(reworded.idea == LedgerIdeaRejection(ideaId: "abc", scope: .notNow, anchor: ["volumeKey": "volume_1"]))
    #expect(redirected.idea == nil)
  }

  @Test func shouldTreatANullPayloadInTheInputAsOmitted() throws {
    var input = supersession()
    input.payload = .null
    #expect(try authorSuccessor(previous(), input).payload == previous().payload)
  }

  @Test func shouldTellActiveSupersededAndWithdrawnEntriesApart() {
    #expect(ledgerEntryStatus(supersededAt: nil, withdrawnReason: nil) == .active)
    #expect(ledgerEntryStatus(supersededAt: Date(timeIntervalSince1970: 1), withdrawnReason: nil) == .superseded)
    #expect(ledgerEntryStatus(supersededAt: Date(timeIntervalSince1970: 1), withdrawnReason: "Dropped") == .withdrawn)
  }
}

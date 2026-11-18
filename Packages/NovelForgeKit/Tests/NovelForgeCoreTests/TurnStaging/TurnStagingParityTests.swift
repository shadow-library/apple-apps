import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private struct TurnFixture {
  let root: OrderedJSONObject

  static func load() throws -> TurnFixture {
    let text = String(decoding: try ReferenceFixture.data("turn-staging/turn-staging.json"), as: UTF8.self)
    return TurnFixture(root: try #require(try OrderedJSON(parsing: text).objectValue))
  }

  func section(_ name: String) throws -> [OrderedJSONObject] {
    try #require(root[name]?.arrayValue).map { try #require($0.objectValue) }
  }
}

private func ops(_ value: OrderedJSON?) throws -> [ChangeOp] {
  try parseChangeSet(try #require(value), options: ChangeSetValidationOptions(entityMaterialization: false))
}

private func number(_ value: OrderedJSON?) -> Int? {
  value?.numberValue.flatMap { Int(exactly: $0) }
}

private func int(_ value: OrderedJSON?) throws -> Int {
  try #require(number(value))
}

private func text(_ value: OrderedJSON?) throws -> String {
  try #require(value?.stringValue)
}

private func list(_ value: OrderedJSON?) throws -> [OrderedJSON] {
  try #require(value?.arrayValue)
}

private func object(_ value: OrderedJSON?) throws -> OrderedJSONObject {
  try #require(value?.objectValue)
}

private func texts(_ value: OrderedJSON?) throws -> [String] {
  try #require(value?.arrayValue).map { try #require($0.stringValue) }
}

private func numbers(_ value: OrderedJSON?) throws -> [Int] {
  try #require(value?.arrayValue).map { try #require(number($0)) }
}

private func storable(_ ops: [ChangeOp]) -> [JSONValue?] {
  ops.map { OrderedJSON.object($0.fields).storable }
}

/// The scripted port of turn-proposals.spec.ts:41-74, with each step as this version takes it: the direct card staged and applied as one step.
private final class ScriptedSteps: TurnStagingSteps {
  struct DirectCall {
    let ops: [ChangeOp]
    let sources: [OpSource]
    let entityMaterialization: Bool
  }

  struct CardCall {
    let ops: [ChangeOp]
    let warnings: [String]
    let entityMaterialization: Bool
    let id: UUID
  }

  let stageFails: [String]
  let directWarns: Bool
  let applyFails: String
  private(set) var direct: DirectCall?
  private(set) var applied = false
  private(set) var cards = [CardCall]()
  /// The notes each step that committed recorded, in order.
  private(set) var recorded = [TurnStagingNotes]()

  init(script: OrderedJSONObject) throws {
    stageFails = try texts(script["stageFails"])
    directWarns = script["directWarns"] == .bool(true)
    applyFails = try text(script["applyFails"])
  }

  func applyDirect(_ ops: [ChangeOp], sources: [OpSource], entityMaterialization: Bool, cardsFollow: Bool, notes: TurnStagingNotes) async -> TurnDirectOutcome {
    direct = DirectCall(ops: ops, sources: sources, entityMaterialization: entityMaterialization)
    if stageFails.contains("direct") { return .failed(note: TurnStagingFlow.failureNote(ProposalStagingError.store(.invalidChange("op not allowed")))) }
    if directWarns { return .warned }
    switch applyFails {
    case "app": return .failed(note: turnApplyConflictNote)
    case "internal": return .failed(note: TurnStagingFlow.failureNote(ProposalApplyError.store(.invalidChange("connection reset by peer at 10.0.0.4"))))
    default:
      applied = true
      recorded.append(notes)
      return .applied(proposal: UUID(), changes: ops.indices.map { ProposalChangeOutcome(index: $0, status: .applied, source: sources[$0]) })
    }
  }

  func stageCards(
    _ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool, notes: @escaping @Sendable (TurnCardStaging) -> TurnStagingNotes
  ) async throws(TurnStagingError) -> TurnCardStaging {
    let role = direct == nil || applied ? "cards" : "all"
    if stageFails.contains(role) { throw .store(.invalidChange("op not allowed")) }
    let id = UUID()
    cards.append(CardCall(ops: ops, warnings: warnings, entityMaterialization: entityMaterialization, id: id))
    let staging = TurnCardStaging(proposal: id, replyNotes: [])
    recorded.append(notes(staging))
    return staging
  }
}

private func disposition(_ disposition: OpDisposition) -> String {
  switch disposition {
  case .direct(_, let source): "d:\(source.rawValue)"
  case .card(_, let reason, let rule?): "c:\(reason.rawValue):\(rule.rawValue)"
  case .card(_, let reason, nil): "c:\(reason.rawValue)"
  }
}

// Fixtures/turn-staging/turn-staging.json, from apps/novel-forge-server/src/modules/refinement/turn-proposals.ts and passage-rewrite.ts
@Suite("Turn staging parity")
struct TurnStagingParityTests {
  // turn-proposals.ts:96
  @Test func shouldHoldATurnByItsWarningsAsTheReferenceDoes() throws {
    let cases = try TurnFixture.load().section("holds")
    #expect(cases.count == 9)
    for (index, entry) in cases.enumerated() {
      #expect(turnHold(try texts(entry["warnings"])).rawValue == entry["expected"]?.stringValue, "case \(index)")
    }
  }

  // turn-proposals.ts:102
  @Test func shouldSplitATurnAndDropItsTurnedDownIdeasAsTheReferenceDoes() throws {
    let cases = try TurnFixture.load().section("splits")
    #expect(cases.count == 165)
    var dropping = 0
    for (index, entry) in cases.enumerated() {
      let given = try ops(entry["ops"])
      let current = try list(entry["current"]).map { pair throws -> (ref: String, fields: OrderedJSONObject) in
        let items = try list(pair)
        return (ref: try text(items.first), fields: try object(items.last))
      }
      let mode = try #require(RefinementChatMode(rawValue: try text(entry["mode"])))
      let context = TurnPolicyContext(
        authorMessage: try text(entry["message"]), mode: mode, justDiscussing: entry["justDiscussing"] == .bool(true), warnings: try texts(entry["warnings"]))
      let rejected = entry["rejected"]
      var asked = [[String]]()
      let split = splitTurnChangeSet(given, context: context, state: WritePolicyState(current: current)) { ids in
        asked.append(ids)
        if rejected?.isNull ?? true { return [] }
        if rejected?.stringValue == "fail" { return nil }
        let listed = Set((rejected?.arrayValue ?? []).compactMap(\.stringValue).map { JSString($0) })
        return Set(ids.map { JSString($0) }.filter(listed.contains))
      }
      let expected = try object(entry["expected"])
      if !(rejected?.isNull ?? true) {
        let wanted = try list(expected["asked"]).map { try texts($0) }
        #expect(asked == wanted, "case \(index): asked")
      }
      #expect(split.split.ops == (try numbers(expected["kept"])).map { given[$0] }, "case \(index): kept")
      #expect(split.split.direct == (try numbers(expected["direct"])).map { given[$0] }, "case \(index): direct")
      #expect(split.split.dispositions.map(disposition) == (try texts(expected["dispositions"])), "case \(index): dispositions")
      #expect(split.split.sources.map(\.rawValue) == (try texts(expected["sources"])), "case \(index): sources")
      #expect(split.split.held.rawValue == expected["held"]?.stringValue, "case \(index): held")
      #expect(split.droppedIdeas == (try texts(expected["droppedIdeas"])), "case \(index): dropped")
      if !split.droppedIdeas.isEmpty { dropping += 1 }
    }
    #expect(dropping > 20)
  }

  // turn-proposals.ts:127
  @Test func shouldStageASplitAsTheReferenceDoesOverAScriptedPort() async throws {
    let fixture = try TurnFixture.load()
    let pool = try ops(fixture.root["pool"])
    let warningPool = try texts(fixture.root["warnings"])
    let cases = try fixture.section("stagings")
    #expect(cases.count == 295)
    for (index, entry) in cases.enumerated() {
      let direct = try numbers(entry["direct"]).map { pool[$0] }
      let cards = try numbers(entry["cards"]).map { pool[$0] }
      let sources = try texts(entry["sources"]).map { try #require(OpSource(rawValue: $0)) }
      let warnings = try numbers(entry["warnings"]).map { warningPool[$0] }
      let held = try #require(WriteHold(rawValue: try text(entry["held"])))
      let all = direct + cards
      let dispositions = all.indices.map { position -> OpDisposition in
        guard position < direct.count else { return .card(index: position, reason: .noQuote, rule: nil) }
        return .direct(index: position, source: sources.indices.contains(position) ? sources[position] : .quoted)
      }
      let split = ChangeSetSplit(ops: all, direct: direct, cards: cards, sources: sources, dispositions: dispositions, held: held)
      let steps = try ScriptedSteps(script: try object(entry["script"]))
      let expected = try object(entry["expected"])

      let result: TurnStagingResult
      do throws(TurnStagingError) {
        result = try await TurnStagingFlow.stage(split, warnings: warnings, steps: steps)
      } catch {
        #expect(expected["threw"] == .bool(true), "case \(index): threw \(error)")
        #expect((error == .misalignedSources ? "internal" : "store") == expected["message"]?.stringValue, "case \(index)")
        continue
      }
      #expect(expected["threw"] == .bool(false), "case \(index) staged what the reference refused")
      if let applied = expected["applied"]?.objectValue {
        let call = try #require(steps.direct)
        #expect(result.appliedProposal != nil, "case \(index)")
        #expect(call.ops == (try numbers(applied["ops"])).map { pool[$0] }, "case \(index): applied ops")
        #expect(call.sources.map(\.rawValue) == (try texts(applied["sources"])), "case \(index): sources")
        #expect(result.applied?.map(\.source) == call.sources.map(Optional.some), "case \(index): outcome sources")
      } else {
        #expect(result.appliedProposal == nil && result.applied == nil, "case \(index)")
      }
      if let materialization = expected["directMaterialization"], !materialization.isNull {
        #expect(steps.direct.map { .bool($0.entityMaterialization) } == materialization, "case \(index): direct materialization")
      }
      if let card = expected["card"]?.objectValue {
        let call = try #require(steps.cards.first { $0.id == result.cardProposal })
        #expect(call.ops == (try numbers(card["ops"])).map { pool[$0] }, "case \(index): card ops")
        #expect(call.warnings == (try numbers(card["warnings"])).map { warningPool[$0] }, "case \(index): card warnings")
        #expect(.bool(call.entityMaterialization) == card["entityMaterialization"], "case \(index): card materialization")
      } else {
        #expect(result.cardProposal == nil, "case \(index)")
      }
      #expect(result.applyNote.map(OrderedJSON.string) ?? .null == expected["applyNote"], "case \(index): note")
      #expect(result.held.map { OrderedJSON.string($0.rawValue) } ?? .null == expected["held"], "case \(index): held")
      #expect(result.replyNote == nil, "case \(index)")
      // the last step that committed records what the reply says, so a turn stopped before it saved the result says the same
      if let last = steps.recorded.last { #expect(last == result.notes, "case \(index): recorded notes") }
    }
  }

  // passage-rewrite.ts:139, :233
  @Test func shouldAnchorATurnsRewritesAndNameTheOnesItLeftOutAsTheReferenceDoes() throws {
    let cases = try TurnFixture.load().section("anchors")
    #expect(cases.count == 75)
    var reasons = Set<RewriteDropReason>()
    var answered = 0
    for (index, entry) in cases.enumerated() {
      let cursor = try int(entry["cursor"])
      var drafts = [Int: AnchorDraft]()
      for item in try list(entry["drafts"]) {
        let row = try object(item)
        let chapter = try int(row["chapter"])
        drafts[chapter] = AnchorDraft(
          id: try text(row["id"]), revision: try int(row["revision"]), saveSeq: try int(row["saveSeq"]), body: try text(row["body"]),
          isolated: row["isolated"] == .bool(true), locked: chapter <= cursor || row["status"]?.stringValue == "final")
      }
      let contexts = try list(entry["contexts"]).map { item throws -> ChatPassageContext in
        let row = try object(item)
        return ChatPassageContext(
          chapter: try int(row["chapter"]), draftId: try text(row["draftId"]), revision: try int(row["revision"]), saveSeq: try int(row["saveSeq"]),
          start: try int(row["start"]), end: try int(row["end"]), passageHash: "", quote: "", comment: "", firstParagraph: 0, lastParagraph: 0)
      }
      let anchored = TurnRewriteAnchoring.anchor(try ops(entry["ops"]), drafts: drafts, unreadable: [], contexts: contexts)
      let expected = try object(entry["expected"])
      let wanted = try list(expected["ops"]).map(\.storable)
      #expect(storable(anchored.ops) == wanted, "case \(index): ops")
      let dropped = try list(expected["dropped"]).map { item throws -> DroppedRewrite in
        let row = try object(item)
        let reason = try #require(RewriteDropReason(rawValue: try text(row["reason"])))
        return DroppedRewrite(chapter: try int(row["chapter"]), label: row["label"]?.stringValue, reason: reason)
      }
      #expect(anchored.dropped.count == dropped.count, "case \(index): dropped")
      for (got, want) in zip(anchored.dropped, dropped) {
        #expect(got.chapter == want.chapter && got.reason == want.reason, "case \(index): dropped")
        #expect(got.label.map { JSString($0) } == want.label.map { JSString($0) }, "case \(index): label")
        reasons.insert(got.reason)
      }
      let note = TurnRewriteAnchoring.droppedNote(anchored.dropped)
      #expect(note.map { JSString($0) } == expected["note"]?.stringValue.map { JSString($0) }, "case \(index): note")
      answered += anchored.ops.filter { $0.passageRewrite?.contextIndex != nil }.count
    }
    #expect(reasons == [.noDraft, .locked, .isolated, .wholeChapter, .notFound, .ambiguous, .unchanged])
    #expect(answered > 10)
  }
}

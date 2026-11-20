import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

/// Proposals are named by the step that staged them and drafts by chapter, so no vault id or clock reaches the comparison.
final class ChatScenarioRunner {
  let book: ChapterBook
  let watch: [String]
  private var labels = [String: UUID]()

  private init(book: ChapterBook, watch: [String]) {
    self.book = book
    self.watch = watch
  }

  private var novel: UUID { book.novel }
  private var store: VaultStore { book.store }

  static func start(_ world: ChatScenarioWorld, vault: JSONValue, watch: [String]) async throws -> ChatScenarioRunner {
    try #require(world.premise == nil, "the native world starts without a premise")
    let clock = OperationClock()
    let reconciler = try Projection.reconciler()
    let store = try VaultStore.open(.inMemory, registry: Projection.registry, migrations: reconciler.migrations, wallClock: clock.function, reconciler: reconciler)
    let book = ChapterBook(store: store, clock: clock)
    let novel = book.novel
    var merged = world.entities
    for override in vault["entities"]?.arrayValue ?? [] {
      if let index = merged.firstIndex(where: { $0["entityKey"] == override["entityKey"] }), case .object(let base) = merged[index],
        case .object(let fields) = override
      {
        merged[index] = .object(base.merging(fields) { _, new in new })
      } else {
        merged.append(override)
      }
    }
    let entities = merged
    let milestones = world.milestones
    let notes = vault["notes"].map { notes in String(repeating: notes["text"]?.stringValue ?? "", count: Int(notes["times"]?.intValue ?? 0)) }
    let mode: ChatSessionMode = vault["mode"]?.stringValue == "manual" ? .manual : .auto
    try await book.run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      for entity in entities { try Self.create(entity, novel: novel, in: &transaction) }
      for milestone in milestones {
        _ = try MilestoneRecord(novel: novel, milestone: milestone["milestoneKey"]?.stringValue ?? "", label: milestone["label"]?.stringValue ?? "").create(in: &transaction)
      }
      if let notes { _ = try AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: notes)).create(in: &transaction) }
      _ = try ChatSessionRecord(id: EngineWorld.session, novel: novel, mode: mode).create(in: &transaction)
    }
    try await book.finalized(through: world.storyCursor)
    #expect(try await book.draftContent(world.storyCursor)?.body == world.finalBody)
    try await book.draft(world.storyCursor + 1, world.draft)
    return ChatScenarioRunner(book: book, watch: watch)
  }

  private static func create(_ entity: JSONValue, novel: UUID, in transaction: inout WriteTransaction) throws {
    let type = try #require(EntityType(rawValue: entity["type"]?.stringValue ?? ""))
    let details = EntityDetails(
      status: entity["status"]?.stringValue, notes: entity["notes"]?.stringValue, motivation: entity["motivation"]?.stringValue, body: entity["body"]?.stringValue)
    try Entities.create(novel: novel, entity: entity["entityKey"]?.stringValue ?? "", type: type, name: entity["name"]?.stringValue ?? "", details, in: &transaction)
  }

  func run(_ step: JSONValue, index: Int) async throws -> JSONValue {
    var outcome: [String: JSONValue]
    if let turn = step["turn"] {
      outcome = try await self.turn(turn, index: index)
    } else if let apply = step["apply"] {
      outcome = try await self.apply(apply)
    } else if let discard = step["discard"] {
      outcome = try await self.discard(discard)
    } else if let reject = step["reject"] {
      outcome = try await self.reject(reject)
    } else if let edit = step["edit"] {
      try await self.edit(edit)
      outcome = ["outcome": "edited"]
    } else {
      throw ChatScenarioMismatch(lines: ["step \(index) does nothing"])
    }
    for (key, value) in try await snapshot() { outcome[key] = value }
    return .object(outcome)
  }

  // MARK: steps

  private func turn(_ turn: JSONValue, index: Int) async throws -> [String: JSONValue] {
    let calls = (turn["calls"]?.arrayValue ?? []).map { call -> [ScriptedModelProvider.Step] in
      guard call["failure"] == nil else { return [.failure(.authentication)] }
      return ScriptedModelProvider.reply(OrderedJSON(call).jsonText)
    }
    let provider = ScriptedModelProvider(calls: calls)
    let engine = try await EngineWorld.engine(store, provider: provider)
    let choices = turn["choices"]
    let chosen = ChatTurnChoices(
      contentMode: choices?["contentMode"]?.stringValue.flatMap(ContentMode.init(rawValue:)), justDiscussing: choices?["justDiscussing"]?.boolValue ?? false,
      proseEdits: choices?["proseEdits"]?.boolValue ?? false)
    let passages = try await self.passages(turn["passages"]?.arrayValue ?? [])
    let handle: ChatTurnHandle
    do {
      handle = try await engine.send(turn["message"]?.stringValue ?? "", passages: passages, session: EngineWorld.session, novel: novel, choices: chosen)
    } catch {
      return ["outcome": .string("refused:\(error.code)")]
    }
    let replyID: UUID
    switch await handle.outcome() {
    case .answered(let reply): replyID = reply
    case .failed(let failure): return ["outcome": .string("failed:\(failure.code)"), "calls": .int(Int64(provider.requests.count))]
    case let other: throw ChatScenarioMismatch(lines: ["the turn ended \(other)"])
    }
    let reply = try #require(try await EngineWorld.messages(in: store).first { $0.id == replyID })
    let label = { (proposal: UUID?, side: String) -> JSONValue in
      guard let proposal else { return .null }
      let name = "s\(index).\(side)"
      self.labels[name] = proposal
      return .string(name)
    }
    let lookups = reply.trace?["sources"]?.arrayValue ?? []
    return [
      "outcome": "answered", "calls": .int(Int64(provider.requests.count)), "lookups": .array(lookups), "reply": .string(reply.content),
      "applyNote": reply.applyNote.map(JSONValue.string) ?? .null, "held": reply.held.map(JSONValue.string) ?? .null, "question": reply.question ?? .null,
      "applied": label(reply.appliedProposal, "applied"), "card": label(reply.cardProposal, "card"),
    ]
  }

  private func passages(_ passages: [JSONValue]) async throws -> [ChatTurnPassage] {
    let novel = novel
    let chapters = passages.compactMap { $0["chapter"]?.intValue }.map { Int($0) }
    let drafts = try await store.read { try ChatTurnDrafts.read(chapters, novel: novel, in: $0) }
    return try passages.map { passage in
      let chapter = Int(passage["chapter"]?.intValue ?? 0)
      let draft = try #require(drafts[chapter])
      let quote = passage["quote"]?.stringValue ?? ""
      let start = draft.record.content.body.jsIndexOf(quote)
      return ChatTurnPassage(
        chapter: chapter, draftId: draft.identity, revision: draft.generation, start: start, end: start + quote.jsLength, passageHash: passageHash(quote), quote: quote,
        comment: passage["comment"]?.stringValue ?? "")
    }
  }

  private func apply(_ apply: JSONValue) async throws -> [String: JSONValue] {
    let proposal = try id(apply["proposal"])
    let selection: ApplySelection = apply["selection"]?.arrayValue.map { .indexes($0.compactMap(\.intValue).map { Int($0) }) } ?? .whole
    let outcome: ProposalApplyOutcome
    do {
      outcome = try await store.applyProposal(proposal, selection: selection, context: ProposalApplyContext(novel: novel, now: book.clock.now))
    } catch {
      return ["outcome": .string("error:\(error.code)")]
    }
    guard case .applied = outcome else { return ["outcome": "conflicted"] }
    return ["outcome": "applied", "results": try await results(of: proposal)]
  }

  private func discard(_ discard: JSONValue) async throws -> [String: JSONValue] {
    do {
      try await store.discardProposal(try id(discard["proposal"]), novel: novel)
      return ["outcome": "discarded"]
    } catch let error as ProposalDecisionError {
      return ["outcome": .string("error:\(error.code)")]
    }
  }

  private func reject(_ reject: JSONValue) async throws -> [String: JSONValue] {
    let scope = try #require(LedgerRejectionScope(rawValue: reject["scope"]?.stringValue ?? ""))
    do {
      try await store.rejectIdea(proposal: try id(reject["proposal"]), opIndex: Int(reject["op"]?.intValue ?? -1), scope: scope, novel: novel)
      return ["outcome": "rejected"]
    } catch let error as IdeaRejectionError {
      return ["outcome": .string("error:\(error.code)")]
    }
  }

  private func edit(_ edit: JSONValue) async throws {
    let novel = novel
    if let entity = edit["entity"] {
      let details = EntityDetails(
        status: entity["status"]?.stringValue, notes: entity["notes"]?.stringValue, motivation: entity["motivation"]?.stringValue, body: entity["body"]?.stringValue)
      let key = entity["entityKey"]?.stringValue ?? ""
      try await book.run { try Entities.edit(novel: novel, entity: key, details, in: &$0) }
    }
    if let entity = edit["newEntity"] {
      try await book.run { try Self.create(entity, novel: novel, in: &$0) }
    }
    if let draft = edit["draft"] {
      let chapter = Int(draft["chapter"]?.intValue ?? 0)
      let (from, to) = (draft["replace"]?[0]?.stringValue ?? "", draft["replace"]?[1]?.stringValue ?? "")
      let body = try #require(try await book.draftContent(chapter)?.body)
      let at = body.jsIndexOf(from)
      try #require(at >= 0)
      try await book.draft(chapter, body.jsSlice(0, at) + to + body.jsSlice(at + from.jsLength))
    }
  }

  private func id(_ label: JSONValue?) throws -> UUID {
    let name = label?.stringValue ?? ""
    guard let id = labels[name] else { throw ChatScenarioMismatch(lines: ["no proposal \(name)"]) }
    return id
  }

  // MARK: reading back

  private func snapshot() async throws -> [String: JSONValue] {
    let (novel, watch, labels) = (novel, watch, labels)
    let roles = try await EngineWorld.messages(in: store).map { JSONValue.string($0.role.rawValue) }
    var proposals = [String: JSONValue]()
    for (label, id) in labels {
      let proposal = try await book.proposal(id)
      let decision = proposal.decision.rawValue
      proposals[label] = [
        "decision": .string(decision), "ops": .array(proposal.card.changeSet.map { normalised($0.stored) }), "warnings": .array(proposal.card.warnings.map(JSONValue.string)),
        "results": decision == ProposalDecision.applied.rawValue ? try await results(of: id) : .null,
      ]
    }
    let records = try await store.read { transaction in
      let refs = watch.filter { !$0.hasPrefix("draft:") }
      let current = try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: transaction)
      var records = [String: JSONValue]()
      for ref in refs { records[ref] = current[ref]?.fields.flatMap { OrderedJSON.object($0).storable } ?? .null }
      return records
    }
    var all = records
    for ref in watch where ref.hasPrefix("draft:") {
      let chapter = try #require(Int(ref.dropFirst("draft:".count)))
      guard let content = try await book.draftContent(chapter) else {
        all[ref] = .null
        continue
      }
      let approved = try await store.write { transaction in
        let head = try transaction.liveDraft(novel: novel, chapter: chapter)
        return try transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision).review == .approved
      }
      all[ref] = ["body": .string(content.body), "approved": .bool(approved)]
    }
    let stored = try await store.read { try ProposalRecord.listing(in: $0).entries.map(\.record).filter { $0.card.novel == novel } }
    var decisions = [String: JSONValue]()
    for proposal in stored { decisions[proposal.decision.rawValue] = .int((decisions[proposal.decision.rawValue]?.intValue ?? 0) + 1) }
    return ["transcript": .array(roles), "proposals": .object(proposals), "decisions": .object(decisions), "records": .object(all)]
  }

  // proposal-apply.service.ts:232-238
  private func results(of id: UUID) async throws -> JSONValue {
    let proposal = try await book.proposal(id)
    let changes = try await store.read { try ProposalChangeRecord.changes(of: proposal, in: $0) }
    let sources = proposal.application?.sources
    return .array(
      changes.enumerated().map { index, change in
        let status: String =
          switch change {
          case .recorded(let record): record.status.rawValue
          case .declined: "declined"
          default: "unrecorded"
          }
        var entry: [String: JSONValue] = ["index": .int(Int64(index)), "status": .string(status)]
        if let source = sources?[safe: index]?.rawValue { entry["source"] = .string(source) }
        return .object(entry)
      })
  }

  // generate.ts normalisedOp
  private func normalised(_ op: JSONValue) -> JSONValue {
    guard case .object(var fields) = op else { return op }
    if case .object(var anchor)? = fields["anchor"] {
      for key in ["draftId", "revision", "saveSeq"] { anchor[key] = nil }
      fields["anchor"] = .object(anchor)
    }
    if fields["op"] == "action.approve_draft" { for key in ["draftId", "revision", "saveSeq"] { fields[key] = nil } }
    return .object(fields)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

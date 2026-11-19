import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// How the author asks for the commit: by chapter number, for the lowest approved chapter (generation.service.ts:604-612), or by a chat card's action.
enum FinalizeRepeatPath: String, CaseIterable, Sendable {
  case named
  case lowest
  case card
}

enum ItemAnswer: Sendable, Equatable {
  case automatic
  case kept
  case skipped
  case edited([String: JSONValue])
  case open
}

struct CaseItem: Sendable {
  let change: ProposedChange
  let triage: FinalizeTriage
  let autoKept: Bool
  let answer: ItemAnswer
}

enum FinalizeAttempt: Sendable, Equatable, Comparable, CustomStringConvertible {
  case finalized(Int)
  case refused(String)

  var description: String {
    switch self {
    case .finalized(let chapter): "finalized \(chapter)"
    case .refused(let code): "refused \(code)"
    }
  }

  static func < (left: FinalizeAttempt, right: FinalizeAttempt) -> Bool { left.description < right.description }
}

struct FinalizeCrash: Error {}

private let pool: [(change: ProposedChange, edit: [String: JSONValue]?)] = [
  (Kept.entity("kael"), ["name": "Kael the Bold"]),
  (Kept.entity("mara", name: "Mara Renamed"), ["notes": "Keeps the lamp."]),
  (Kept.entity("ghost"), nil),
  (Kept.appearance("mara"), nil),
  (Kept.appearance("kael"), nil),
  (Kept.state("mara", location: "the tower"), ["location": "the sea"]),
  (Kept.state("kael", location: "the pier", conditions: ["tired"]), ["conditions": ["wounded"]]),
  (Kept.relationship("mara", "kael", "rival"), ["note": "wary"]),
  (Kept.thread("ledger", .closed, summary: "Paid."), ["status": "open"]),
  (Kept.knowledge("kael", "heir"), ["how": "A letter."]),
  (Kept.knowledge("mara", "tide"), nil),
  (Kept.milestone("rise"), ["reached": false]),
  (Kept.milestone("fall", reached: false), ["reached": true]),
  (.summary(text: "It turns twice."), ["text": "It turns again."]),
]

/// One finalize review state: the chapter (2 has a final chapter 1 before it), its isolation, the plan's knowledge pairs and claims, the novel's auto-keep
/// categories, and each item of the review with how the author answered it.
struct FinalizeCase: Sendable, CustomStringConvertible {
  let chapter: Int
  let isolated: Bool
  let path: FinalizeRepeatPath
  let learns: [KnowledgeReveal]
  let claims: [String]
  let autoKeep: [FinalizeCategory]
  let items: [CaseItem]

  static func generate(_ generator: inout SeededGenerator) -> FinalizeCase {
    let isolated = generator.chance(0.3)
    let autoKeep = FinalizeCategory.allCases.filter { _ in generator.chance(0.4) }
    let chosen = generator.shuffled(pool).prefix(generator.int(in: 0...7))
    var items = chosen.map { entry -> CaseItem in
      let triage: FinalizeTriage = generator.chance(0.35) ? .consequential : .routine
      let autoKept = !isolated && triage == .routine && autoKeep.contains(entry.change.category)
      let answers: [ItemAnswer] = [.kept, .skipped] + (entry.edit.map { [.edited($0)] } ?? [])
      let answer: ItemAnswer = autoKept && generator.chance(0.5) ? .automatic : generator.pick(from: answers)
      return CaseItem(change: entry.change, triage: triage, autoKept: autoKept, answer: answer)
    }
    if let unanswered = items.indices.filter({ !items[$0].autoKept }).randomElement(using: &generator), generator.chance(0.15) {
      let item = items[unanswered]
      items[unanswered] = CaseItem(change: item.change, triage: item.triage, autoKept: false, answer: .open)
    }
    return FinalizeCase(
      chapter: generator.chance(0.35) ? 2 : 1, isolated: isolated, path: generator.pick(from: FinalizeRepeatPath.allCases),
      learns: generator.chance(0.5) ? [reveal("mara", "heir")] : [], claims: ["rise", "fall"].filter { _ in generator.chance(0.5) }, autoKeep: autoKeep,
      items: Array(items))
  }

  var stored: [StoredFinalizeItem] {
    items.enumerated().map { position, item in ReviewItems.item(item.change, triage: item.triage, position: position, autoKept: item.autoKept) }
  }

  var open: Int { items.filter { $0.answer == .open }.count }

  var kept: [CaseItem] {
    items.filter { item in
      switch item.answer {
      case .kept, .edited: true
      case .automatic: item.autoKept
      case .skipped, .open: false
      }
    }
  }

  /// A committed review that keeps an entity the novel has no record of, which the commit creates.
  var createsEntity: Bool {
    open == 0
      && kept.contains { item in
        guard case .entity(let entity) = item.change else { return false }
        return entity.entityKey != "mara"
      }
  }

  /// The first commit's answer: every item answered or kept on its own commits, an open one refuses FRV_005 (finalize-review-gate.ts:55).
  var first: FinalizeAttempt {
    open > 0 ? .refused(FinalizeRefusal.unanswered(count: open).code) : .finalized(chapter)
  }

  /// What the same path answers the second time: a card already applied refuses RFN_002 (proposal-apply.service.ts:118-119); once final, the chapter refuses
  /// DRF_002 (finalize-refusals.ts:13) and the lowest approved one DRF_001, as commitProse sets reviewStatus final (chapter-finalization.graph.ts:183,
  /// generation.service.ts:604-613); a refused commit refuses again as it did.
  var again: FinalizeAttempt {
    if path == .card { return .refused(ProposalApplyError.notPending(.known(.applied)).code) }
    guard open == 0 else { return first }
    return path == .named ? .refused(DomainError.draftFinal(chapter).code) : .refused(DomainError.draftNotFound(nil).code)
  }

  var description: String {
    let answered = items.map { "\($0.change.itemKey)[\($0.triage.rawValue)\($0.autoKept ? ",auto" : "")]=\($0.answer)" }
    return "chapter \(chapter) \(isolated ? "isolated" : "standard") via \(path) learns=\(learns.map(\.factKey)) claims=\(claims) auto=\(autoKeep.map(\.rawValue)) \(answered)"
  }
}

extension ChapterBook {
  /// The case's state up to the commit: the novel, its earlier final chapter, the plan, the draft, its approval, the review read and the author's answers,
  /// and for the card path the staged card; returns the card.
  func prepare(_ finalizeCase: FinalizeCase) async throws -> UUID? {
    let novel = novel
    try await run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 5, in: &transaction)
      for milestone in ["rise", "fall"] { try PlanWorldWrites.milestone(novel: novel, milestone, in: &transaction) }
      _ = try ThreadRecord(novel: novel, thread: "ledger", summary: "Owed.").create(in: &transaction)
      _ = try FinalizeReviewDecisions.setAutoKeep(novel: novel, categories: finalizeCase.autoKeep, in: &transaction)
    }
    let chapter = finalizeCase.chapter
    if chapter == 2 {
      try await plan(1)
      try await draft(1)
      try await approve(1, id: SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000a1"))
      try await reviewRead(1, items: [ReviewItems.item(Kept.appearance("mara"), autoKept: true)])
      try await run { try FinalizeReviews.finalize(novel: novel, chapter: 1, in: &$0) }
    }
    try await plan(chapter, learns: finalizeCase.learns, claims: finalizeCase.claims)
    let state: [String: JSONValue]? = finalizeCase.isolated ? ["lastBeat": "Mara leaves the tower"] : nil
    try await draft(chapter, body: "Mara climbs the tower in chapter \(chapter).", summary: "Mara climbs.", isolated: finalizeCase.isolated, state: state)
    try await approve(chapter, id: SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000a2"))
    try await reviewRead(chapter, items: finalizeCase.stored)
    for item in finalizeCase.items {
      switch item.answer {
      case .automatic, .open: continue
      case .kept: try await answer(chapter, item: item.change.itemKey, .kept)
      case .skipped: try await answer(chapter, item: item.change.itemKey, .skipped, reason: "Not yet.")
      case .edited(let edit): try await answer(chapter, item: item.change.itemKey, .edited, edit: edit)
      }
    }
    guard finalizeCase.path == .card else { return nil }
    return try await stage(#"{"op":"action.finalize","upTo":\#(chapter)}"#).proposal.id
  }

  func attempt(_ finalizeCase: FinalizeCase, card: UUID?) async -> FinalizeAttempt {
    switch finalizeCase.path {
    case .named: await finalizeDirectly(finalizeCase.chapter)
    case .lowest: await finalizeDirectly(nil)
    case .card: await accept(card, chapter: finalizeCase.chapter)
    }
  }

  func finalizeDirectly(_ chapter: Int?) async -> FinalizeAttempt {
    do throws(DomainError) {
      return .finalized(try await store.finalizeChapter(novel: novel, chapter: chapter))
    } catch {
      return .refused(error.code)
    }
  }

  func accept(_ card: UUID?, chapter: Int) async -> FinalizeAttempt {
    guard let card else { return .refused("no card") }
    do throws(ProposalApplyError) {
      guard case .applied(let changes) = try await store.applyProposal(card, selection: .indexes([0]), context: context()), let change = changes.first else {
        return .refused("conflicted")
      }
      if let failure = change.failure { return .refused(failure.code) }
      if change.status == .applied { return .finalized(chapter) }
      return await settledFailure(card) ?? .refused(change.status.rawValue)
    } catch {
      return .refused(error.code)
    }
  }

  /// The refusal another run of the card's action settled, which an apply that found it settled reports without its failure.
  private func settledFailure(_ card: UUID) async -> FinalizeAttempt? {
    guard let stored = try? await change(card, 0).result?.result?["code"]?.stringValue else { return nil }
    return .refused(stored)
  }

  /// A process that ends inside the commit's transaction, the card's action's once its content committed: the commit runs in full and its transaction never
  /// commits.
  func crashInsideCommit(_ finalizeCase: FinalizeCase, card: UUID?) async throws {
    let (novel, chapter, requester) = (novel, finalizeCase.chapter, store.replica)
    if let card {
      try await expectCrash { transaction in
        _ = try ProposalApply.runAction(proposal: card, index: 0, novel: novel, requester: requester, in: &transaction)
      }
      return
    }
    let named = finalizeCase.path == .named ? chapter : nil
    try await expectCrash { transaction in _ = try ChapterFinalize.finalize(novel: novel, chapter: named, in: &transaction) }
  }

  /// The relaunch after `crashInsideCommit`: the launch sweep for a card, the author's finalize again otherwise.
  func resumeAfterCrash(_ finalizeCase: FinalizeCase, card: UUID?) async -> FinalizeAttempt {
    guard let card else { return await attempt(finalizeCase, card: nil) }
    guard case .resumed(_, let results) = await store.resumePendingActions().first, let result = results.first else { return .refused("not resumed") }
    if let failure = result.failure { return .refused(failure.code) }
    return result.outcome == .known(.applied) ? .finalized(finalizeCase.chapter) : .refused(result.outcome.rawValue)
  }

  private func expectCrash(_ body: @escaping BookWrite<Void>) async throws {
    do {
      try await store.write { transaction in
        try body(&transaction)
        throw FinalizeCrash()
      }
    } catch {
      guard case .aborted = error else { throw error }
    }
  }
}

/// Every table of the store's database, row by row with its clocks, as bytes: two dumps are equal only when nothing was written in between.
enum VaultDump {
  static func everything(in store: VaultStore) async throws -> [String] {
    try await store.read { transaction in
      let database = transaction.database
      let tables = try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      return try tables.flatMap { table in try Row.fetchAll(database, sql: "SELECT * FROM \"\(table)\"").map { "\(table) \(line($0))" }.sorted() }
    }
  }

  /// Every synced value without the clock that stamped it, but the jobs, whose request names the requesting replica (`FinalizeFootprint.jobs`).
  static func values(in store: VaultStore) async throws -> [String] {
    let jobs = JobSchema.jobKind.rawValue
    return try await store.read { transaction in
      let database = transaction.database
      let queries = [
        "SELECT kind, key, slot, name, value FROM field_state WHERE scope = 0 AND kind != '\(jobs)'", "SELECT kind, key, item FROM appended_item WHERE scope = 0",
        "SELECT kind, key, id, item FROM revision WHERE scope = 0", "SELECT kind, key FROM tombstone WHERE scope = 0",
      ]
      return try queries.flatMap { sql in try Row.fetchAll(database, sql: sql).map(line) }.sorted()
    }
  }

  private static func line(_ row: Row) -> String {
    zip(row.columnNames, row.databaseValues).map { name, value in
      switch value.storage {
      case .null: "\(name)=null"
      case .int64(let number): "\(name)=\(number)"
      case .double(let number): "\(name)=\(number)"
      case .string(let text): "\(name)=\"\(text)\""
      case .blob(let bytes): "\(name)=\(String(data: bytes, encoding: .utf8) ?? bytes.map { String(format: "%02x", $0) }.joined())"
      }
    }.joined(separator: " ")
  }
}

/// What a commit leaves that every replica of the same synced state must agree on: the canon's stored bytes and digest, every other synced value, the jobs
/// without their requesting replica, and the views of the derivations the canon feeds.
struct FinalizeFootprint: Equatable, CustomStringConvertible {
  let canon: String?
  let digest: String?
  let values: [String]
  let jobs: [String]
  let derived: [String]

  static func read(_ book: ChapterBook, chapter: Int) async throws -> FinalizeFootprint {
    let (novel, store) = (book.novel, book.store)
    let stored = try await store.read { transaction -> JSONValue? in
      guard case .revisioned(let state)? = try transaction.state(of: try FinalChapterRecord.ref(novel: novel, chapter: chapter)) else { return nil }
      return state[field: FinalChapterField.canon.rawValue]?.value
    }
    let jobs = try await store.read { transaction in
      try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }.map { job in
        "\(job.request.key.ref.key.rawValue) \(CanonicalText.of(job.request.payload)) \(CanonicalText.of(job.request.origin)) \(job.cancel)"
      }
    }
    var derived = try await CanonTables.appearances(novel, in: store).sorted()
    derived += try await CanonTables.states(novel, in: store).map(\.description).sorted()
    derived += try await CanonTables.relationships(novel, in: store).sorted()
    derived += try await CanonTables.events(novel, in: store).map(Self.event).sorted()
    derived += try await CanonTables.promises(novel, in: store).values.map(\.description).sorted()
    derived += try await PlanWorldTables.milestones(novel, in: store).map { "\($0.key) \($0.value)" }.sorted()
    derived += try await ChapterTables.knowledge(novel, in: store).map(\.description).sorted()
    derived += try await ChapterTables.views(novel, in: store).map { "\($0.key) \($0.value)" }.sorted()
    return FinalizeFootprint(
      canon: stored.map(CanonicalText.of), digest: stored.map(FinalChapterRecord.digest), values: try await VaultDump.values(in: store), jobs: jobs.sorted(),
      derived: derived)
  }

  /// Without the derived views, which a commit that creates an entity on two devices loses part of once they sync (the disabled
  /// `shouldKeepTheNewEntitysAppearanceWhenTwoDevicesFinalizeTheSameState`).
  var recorded: FinalizeFootprint { FinalizeFootprint(canon: canon, digest: digest, values: values, jobs: jobs, derived: []) }

  private static func event(_ event: EventView) -> String {
    let json = { (value: JSONValue?) in value.map(CanonicalText.of) ?? "null" }
    return "\(event.entity)@\(event.chapter) \(event.kind.rawValue) \(event.detail) \(json(event.before)) -> \(json(event.after))"
  }

  func difference(from other: FinalizeFootprint) -> String {
    let lines = { (footprint: FinalizeFootprint) in
      [footprint.canon ?? "no canon", footprint.digest ?? "no digest"] + footprint.values + footprint.jobs + footprint.derived
    }
    let (mine, theirs) = (lines(self), lines(other))
    let missing = theirs.filter { !mine.contains($0) }
    let extra = mine.filter { !theirs.contains($0) }
    return "missing \(missing)\nextra \(extra)"
  }

  var description: String { "\(digest ?? "no canon") \(values.count) values \(jobs) \(derived)" }
}

enum CanonicalText {
  static func of(_ value: JSONValue) -> String {
    String(decoding: CanonicalJSON.encode(value), as: UTF8.self)
  }
}

struct IdempotenceFailure: Error, CustomStringConvertible {
  let description: String
}

func labelled(_ scenario: String, _ body: () async throws -> Void) async throws {
  do {
    try await body()
  } catch {
    throw IdempotenceFailure(description: "\(scenario): \(error)")
  }
}

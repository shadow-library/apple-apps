import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Synchronization
import Testing

@testable import NovelForgeCore

private let learners = ["mara", "tobin"]
private let factKeys = ["heir", "tide"]
private let milestoneKeys = ["rise", "fall"]
private let sources: [DraftSource] = [.generated, .revised, .handEdited, .chatEdited, .restored]

enum ChapterOperations {
  static func contract(_ generator: inout SeededGenerator) -> ChapterContract {
    let learns = (0..<generator.int(in: 0...2)).map { _ in Learn(generator.pick(from: learners + ["ghost"]), generator.pick(from: factKeys + ["ghost"])) }
    let claims = milestoneKeys.filter { _ in generator.chance(0.25) }
    return NovelForgeCoreTests.contract(pov: generator.chance(0.85) ? ["mara"] : [""], learns: learns, claims: claims)
  }

  static func secret(_ generator: inout SeededGenerator, novel: UUID) -> SecretRecord {
    let unlock: JSONValue? = generator.chance(0.2) ? NovelForgeCoreTests.unlock(.milestone(generator.pick(from: milestoneKeys))) : nil
    return SecretRecord(
      novel: novel, secret: generator.pick(from: factKeys), text: "A secret.", revealChapter: generator.pick(from: [1, 1, 2, 3]), unlock: unlock, source: .known(.manual))
  }

  private static func pair(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> (UUID, String, String) {
    (universe.novel(&generator), generator.pick(from: factKeys), generator.pick(from: learners))
  }

  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "seed secrets, learners and milestones", weight: 4) { generator, universe in
      let novel = universe.novel(&generator)
      let secrets = factKeys.map { key in
        SecretRecord(novel: novel, secret: key, text: key, revealChapter: generator.pick(from: [1, 1, 2]), unlock: nil, source: .known(.manual))
      }
      return { transaction in
        for record in secrets where try SecretRecord.read(record.ref, in: transaction) == .absent { _ = try record.create(in: &transaction) }
        for key in learners { try ChapterWrites.entity(novel: novel, key, in: &transaction) }
        for key in milestoneKeys where try MilestoneRecord.read(novel: novel, milestone: key, in: transaction) == .absent {
          try PlanWorldWrites.milestone(novel: novel, key, in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "plan, draft and approve a chapter that teaches", weight: 3) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      let planned = NovelForgeCoreTests.contract(learns: [Learn(generator.pick(from: learners), generator.pick(from: factKeys))])
      return { transaction in
        try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(planned), in: &transaction)
        try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction)
        try ChapterWrites.approve(novel: novel, chapter: chapter, id: id, in: &transaction)
      }
    },
    ProjectionOperation(name: "revise a plan", weight: 7) { generator, universe in
      let (novel, chapter, planned) = (universe.novel(&generator), universe.chapter(&generator), contract(&generator))
      return { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(planned), in: &transaction) }
    },
    ProjectionOperation(name: "remove a plan", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: &transaction) }
    },
    ProjectionOperation(name: "write a draft", weight: 8) { generator, universe in
      let (novel, chapter, body) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator))
      let source = generator.pick(from: sources)
      let roll = generator.int(in: 0...19)
      let recording: UpstreamRecording =
        roll < 17 ? .current : roll < 19 ? .none : .given(DraftUpstream(entries: [.draft(chapter: 1, revision: "v:ghost", taught: nil)]))
      return { transaction in try ChapterWrites.draft(novel: novel, chapter: chapter, body: body, source: source, recording: recording, in: &transaction) }
    },
    ProjectionOperation(name: "remove a draft", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in try ChapterWrites.removeDraft(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "write an unreadable draft head", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try transaction.revise(try DraftRecord.ref(novel: novel, chapter: chapter), body: .object(["body": .int(1)])) }
    },
    ProjectionOperation(name: "approve a draft", weight: 6) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      return { transaction in try ChapterWrites.approve(novel: novel, chapter: chapter, id: id, in: &transaction) }
    },
    ProjectionOperation(name: "draft and approve a chapter", weight: 4) { generator, universe in
      let (novel, chapter, body, id) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator), generator.uuid())
      return { transaction in
        try ChapterWrites.draft(novel: novel, chapter: chapter, body: body, in: &transaction)
        try ChapterWrites.approve(novel: novel, chapter: chapter, id: id, in: &transaction)
      }
    },
    ProjectionOperation(name: "approve a draft as written", weight: 3) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      return { transaction in try ChapterWrites.approve(novel: novel, chapter: chapter, kind: .asWritten, id: id, in: &transaction) }
    },
    ProjectionOperation(name: "approve under other terms", weight: 1) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      let terms = ChapterFingerprint.planTerms(contract(&generator))
      return { transaction in
        guard let head = try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction) else { return }
        _ = try ApprovalRecord(id: id, novel: novel, chapter: chapter, draftRevision: head, planRevision: "v:plan", planTermsDigest: terms).append(in: &transaction)
      }
    },
    ProjectionOperation(name: "append an unreadable approval", weight: 1) { generator, universe in
      let (novel, id) = (universe.novel(&generator), generator.uuid())
      return { transaction in _ = try transaction.append(ApprovalRecord.ref(id), item: ["novel": novel.json, "chapter": "one"]) }
    },
    ProjectionOperation(name: "finalize a chapter", weight: 2) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "finalize the next chapter", weight: 2) { generator, universe in
      let novel = universe.novel(&generator)
      return { transaction in
        for chapter in universe.chapters where try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: transaction) == .absent {
          return try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "finalize from another revision", weight: 1) { generator, universe in
      let (novel, chapter, planned) = (universe.novel(&generator), universe.chapter(&generator), contract(&generator))
      return { transaction in
        _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(draftRevision: "v:elsewhere", body: "Else.", contract: planned)).finalize(in: &transaction)
      }
    },
    ProjectionOperation(name: "purge a final chapter", weight: 1) { generator, universe in
      let (novel, chapter, purges) = (universe.novel(&generator), universe.chapter(&generator), generator.chance(0.5))
      return { transaction in if purges { _ = try transaction.purge(try FinalChapterRecord.ref(novel: novel, chapter: chapter)) } }
    },
    ProjectionOperation(name: "amend a final chapter", weight: 1) { generator, universe in
      let (novel, chapter, text) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator))
      return { transaction in
        let ref = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
        guard case .readable = try FinalChapterRecord.read(ref, in: transaction) else { return }
        _ = try FinalChapterRecord.amend(ref, FinalChapterText(body: text), in: &transaction)
      }
    },
    ProjectionOperation(name: "edit a secret's schedule", weight: 3) { generator, universe in
      let record = secret(&generator, novel: universe.novel(&generator))
      var edit = SecretEdit()
      edit.revealChapter = .set(record.revealChapter)
      edit.unlock = .set(record.unlock)
      let changes = edit
      return { transaction in _ = try SecretRecord.edit(record.ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "remove a secret", weight: 1) { generator, universe in
      let ref = secret(&generator, novel: universe.novel(&generator)).ref
      return { transaction in _ = try SecretRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore a secret", weight: 1) { generator, universe in
      let record = secret(&generator, novel: universe.novel(&generator))
      return { transaction in _ = try record.restore(in: &transaction) }
    },
    ProjectionOperation(name: "remove a learner", weight: 1) { generator, universe in
      let (novel, key) = (universe.novel(&generator), generator.pick(from: learners))
      return { transaction in _ = try EntityRecord.remove(novel: novel, entity: key, in: &transaction) }
    },
    ProjectionOperation(name: "restore a learner", weight: 1) { generator, universe in
      let (novel, key) = (universe.novel(&generator), generator.pick(from: learners))
      return { transaction in try ChapterWrites.entity(novel: novel, key, in: &transaction) }
    },
    ProjectionOperation(name: "reveal by hand", weight: 2) { generator, universe in
      let ((novel, fact, entity), chapter) = (pair(&generator, universe), universe.chapter(&generator))
      return { transaction in try ChapterWrites.reveal(novel: novel, fact: fact, entity: entity, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "retract", weight: 2) { generator, universe in
      let (novel, fact, entity) = pair(&generator, universe)
      return { transaction in try ChapterWrites.retract(novel: novel, fact: fact, entity: entity, in: &transaction) }
    },
  ]
}

extension ChapterOperations {
  /// One novel and its first chapters, so short runs reach the chains of writes a stale knowledge or canon cause needs.
  static let focused: [ProjectionOperation] = [
    ProjectionOperation(name: "seed the first novel", weight: 2) { _, universe in
      let novel = universe.novels[0]
      return { transaction in
        for key in factKeys where try SecretRecord.read(novel: novel, secret: key, in: transaction) == .absent {
          try PlanWorldWrites.secret(novel: novel, key, revealChapter: 1, in: &transaction)
        }
        for key in learners { try ChapterWrites.entity(novel: novel, key, in: &transaction) }
      }
    },
    ProjectionOperation(name: "plan, draft and approve an early chapter", weight: 3) { generator, universe in
      let (novel, chapter, id) = (universe.novels[0], generator.int(in: 1...2), generator.uuid())
      let planned = NovelForgeCoreTests.contract(learns: [Learn(generator.pick(from: learners), generator.pick(from: factKeys))])
      return { transaction in
        try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(planned), in: &transaction)
        try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction)
        try ChapterWrites.approve(novel: novel, chapter: chapter, id: id, in: &transaction)
      }
    },
    ProjectionOperation(name: "draft a later chapter", weight: 3) { generator, universe in
      let (novel, chapter) = (universe.novels[0], generator.int(in: 2...3))
      return { transaction in try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "redraft the first chapter", weight: 2) { generator, universe in
      let (novel, body) = (universe.novels[0], universe.text(&generator))
      return { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: body, source: .revised, in: &transaction) }
    },
    ProjectionOperation(name: "approve a later chapter as written", weight: 3) { generator, universe in
      let (novel, chapter, id) = (universe.novels[0], generator.int(in: 2...3), generator.uuid())
      return { transaction in try ChapterWrites.approve(novel: novel, chapter: chapter, kind: .asWritten, id: id, in: &transaction) }
    },
    ProjectionOperation(name: "replan the first chapter", weight: 2) { generator, universe in
      let (novel, planned) = (universe.novels[0], contract(&generator))
      return { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(planned), in: &transaction) }
    },
    ProjectionOperation(name: "finalize the first novel's next chapter", weight: 2) { _, universe in
      let novel = universe.novels[0]
      return { transaction in
        for chapter in universe.chapters where try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: transaction) == .absent {
          return try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "purge the first final chapter", weight: 1) { _, universe in
      let novel = universe.novels[0]
      return { transaction in _ = try transaction.purge(try FinalChapterRecord.ref(novel: novel, chapter: 1)) }
    },
  ]
}

extension ChapterOperations {
  /// A secret of the first novel removed or restored after a chapter recorded it, so its disclosure waits on when it became live again.
  static let recreating: [ProjectionOperation] = [
    ProjectionOperation(name: "remove a secret of the first novel", weight: 3) { generator, universe in
      let ref = SecretRecord.ref(novel: universe.novels[0], secret: generator.pick(from: factKeys))
      return { transaction in _ = try SecretRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore a secret of the first novel", weight: 3) { generator, universe in
      let record = SecretRecord(
        novel: universe.novels[0], secret: generator.pick(from: factKeys), text: "The ledger is forged.", revealChapter: 1, unlock: nil, source: .known(.manual))
      return { transaction in _ = try record.restore(in: &transaction) }
    },
  ]
}

private enum OraclePlan {
  case none
  case contract(ChapterContract)
  case unreadable
}

private struct OracleDraft {
  let head: String?
  let source: String?
  let upstream: DraftUpstream?
}

private struct OracleFinal {
  let digest: String?
  let draft: String?
  let contract: ChapterContract?
  let clock: HLCTimestamp?
  let recorded: [String]?
  let finalized: HLCTimestamp?
}

private struct OracleNovel {
  var finals = [Int: OracleFinal]()
  var drafts = [Int: OracleDraft]()
  var plans = [Int: OraclePlan]()
  var approvals = [Int: [AppendedEntry<ApprovalRecord>]]()
  var reveals = [Int: String]()
}

private func attributed(_ ref: EntityRef, _ state: EntityState?) -> Bool {
  guard let state else { return false }
  return (try? NovelForgeKey(reading: state, of: ref)) != nil
}

private func read(_ novel: UUID, _ universe: ProjectionUniverse, in transaction: ReadTransaction, reveals: [PlanRevealEntry]) throws -> OracleNovel {
  var world = OracleNovel()
  for chapter in universe.chapters {
    let finalRef = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    let finalState = try transaction.state(of: finalRef, scope: .vault)
    let reading = FinalChapterRecord.reading(finalState, of: finalRef)
    let isFinal =
      switch reading {
      case .absent: false
      case .readable: true
      case .unreadable: attributed(finalRef, finalState)
      }
    if isFinal, case .revisioned(let state)? = finalState {
      let canon = state[field: "canon"]?.value
      let members = canon?.objectValue
      let volumeReadable = members?["volume"].map { $0.isNull || $0.stringValue != nil } ?? true
      let contract = volumeReadable ? members?["contract"].flatMap(ChapterContract.init(json:)) : nil
      let canonClock = state[field: "canon"]?.clock
      var clock = canonClock
      if let id = members?["approval"].flatMap(UUID.init(json:)) {
        clock = nil
        if case .readable(let approval) = try ApprovalRecord.read(id: id, in: transaction), approval.record.novel == novel {
          clock = canonClock.map { min($0, approval.clock) } ?? approval.clock
        }
      }
      world.finals[chapter] = OracleFinal(
        digest: canon.map(FinalChapterRecord.digest), draft: members?["draft_revision"]?.stringValue, contract: contract, clock: clock,
        recorded: reading.entry == nil ? nil : recorded(members?["disclosed"]), finalized: canonClock)
    }
    let draftRef = try DraftRecord.ref(novel: novel, chapter: chapter)
    let draftState = try transaction.state(of: draftRef, scope: .vault)
    if case .revisioned(let state)? = draftState {
      switch DraftRecord.reading(draftState, of: draftRef) {
      case .readable(let entry) where !entry.isRemoved:
        world.drafts[chapter] = OracleDraft(head: state.headRevision, source: entry.record.content.source.rawValue, upstream: entry.record.content.upstream)
      case .unreadable where attributed(draftRef, draftState):
        world.drafts[chapter] = OracleDraft(head: state.headRevision, source: nil, upstream: nil)
      default: break
      }
    }
    let planRef = try ChapterPlanRecord.ref(novel: novel, chapter: chapter)
    let planState = try transaction.state(of: planRef, scope: .vault)
    switch ChapterPlanRecord.reading(planState, of: planRef) {
    case .readable(let entry) where !entry.isRemoved: world.plans[chapter] = .contract(entry.record.content.contract)
    case .unreadable where attributed(planRef, planState): world.plans[chapter] = .unreadable
    default: break
    }
    world.approvals[chapter] = try ApprovalRecord.listing(novel: novel, chapter: chapter, in: transaction).entries
  }
  for verdict in reveals where verdict.status == .violated { world.reveals[verdict.chapter] = verdict.reason }
  return world
}

// An independent reading of rules 2 to 7, chapter by chapter from the records.
private func expectedLifecycle(_ novel: UUID, _ world: OracleNovel) -> [Int: ChapterLifecycleEntry] {
  var entries = [Int: ChapterLifecycleEntry]()
  let chapters = Set(world.finals.keys).union(world.drafts.keys).union(world.plans.keys).sorted()
  for chapter in chapters {
    let draft = world.drafts[chapter]
    if let final = world.finals[chapter] {
      entries[chapter] = ChapterLifecycleEntry(
        novel: novel, chapter: chapter, isFinal: true, draft: draft?.head, resting: final.draft, canonDigest: final.digest,
        taught: nil, review: .final, approval: nil, approvalKind: nil, stale: nil, planStale: nil, differences: nil, judge: nil, openBlocking: 0)
      continue
    }
    let reveal = world.reveals[chapter].map(StaleCause.reveal(violations:))
    guard let draft else {
      entries[chapter] = ChapterLifecycleEntry(
        novel: novel, chapter: chapter, isFinal: false, draft: nil, resting: nil, canonDigest: nil, taught: nil, review: nil, approval: nil, approvalKind: nil, stale: nil,
        planStale: reveal, differences: nil, judge: nil, openBlocking: 0)
      continue
    }
    var causes = [(StaleCause, JSONValue)]()
    let upstream = draft.upstream.flatMap { recorded in shaped(recorded, chapter) ? recorded : nil }
    if let upstream {
      for entry in upstream.entries {
        let now = entries[entry.chapter]
        switch entry {
        case .canon(let ancestor, let digest):
          let current = now?.isFinal == true ? now?.canonDigest : nil
          if current != digest { causes.append((.canonReplaced(chapter: ancestor), ["chapter": ancestor.json, "canon": current.json])) }
        case .draft(let ancestor, let revision, let taught):
          if now?.resting != revision {
            let change: AncestorChange
            if now?.isFinal == true {
              change = .finalized
            } else if now?.resting == nil {
              change = .removed
            } else if revision == nil {
              change = .drafted
            } else {
              change = .rewritten(source: world.drafts[ancestor]?.source)
            }
            causes.append((.ancestorDraft(chapter: ancestor, change: change), ["chapter": ancestor.json, "draft": (now?.resting).json]))
          }
          let teaches = now?.isFinal == true ? world.finals[ancestor]?.contract.map(ChapterFingerprint.learns) : now?.taught
          if taught != nil, teaches != taught {
            let lost = teaches == nil && now?.isFinal != true && planLearns(world.plans[ancestor]) == taught
            causes.append((.ancestorKnowledge(chapter: ancestor, lost: lost), ["chapter": ancestor.json, "taught": teaches.json]))
          }
        }
      }
    } else {
      let frontier = entries.values.filter { $0.isFinal && $0.chapter < chapter }.map(\.chapter).max() ?? 0
      let snapshot: [JSONValue] =
        chapter == 1
        ? []
        : (max(frontier, 1)..<chapter).map { ancestor in
          let now = entries[ancestor]
          if now?.isFinal == true { return ["chapter": ancestor.json, "canon": (now?.canonDigest).json] }
          return ["chapter": ancestor.json, "draft": (now?.resting).json, "taught": (now?.taught).json]
        }
      causes.append((.unrecorded, ["unrecorded": true, "upstream": ["chapters": .array(snapshot)]]))
    }
    let differences = causes.isEmpty ? nil : ChapterFingerprint.digest(.array(causes.map(\.1)))
    let ofHead = (world.approvals[chapter] ?? []).filter { $0.record.approvalKind.known != nil && draft.head != nil && $0.record.draftRevision == draft.head }
    let accepted = ofHead.contains { $0.record.approvalKind == .known(.asWritten) && differences != nil && $0.record.upstreamDigest == differences }
    let stale = accepted ? reveal : causes.first?.0 ?? reveal
    let terms: (learns: String, terms: String)? =
      switch world.plans[chapter] ?? .none {
      case .none: (ChapterFingerprint.learns(ChapterContract()), ChapterFingerprint.planTerms(nil))
      case .contract(let planned): (ChapterFingerprint.learns(planned), ChapterFingerprint.planTerms(planned))
      case .unreadable: nil
      }
    var approval: AppendedEntry<ApprovalRecord>?
    var taught: String?
    if stale == nil, let terms {
      approval = ofHead.last { $0.record.planTermsDigest == terms.terms }
      if ofHead.contains(where: { $0.record.planTermsDigest?.split(separator: ":").first.map(String.init) == terms.learns }) { taught = terms.learns }
    }
    entries[chapter] = ChapterLifecycleEntry(
      novel: novel, chapter: chapter, isFinal: false, draft: draft.head, resting: draft.head, canonDigest: nil, taught: taught,
      review: approval == nil ? .needsReview : .approved, approval: approval?.record.id, approvalKind: approval?.record.approvalKind.known, stale: stale,
      planStale: reveal, differences: differences, judge: nil, openBlocking: 0)
  }
  return entries
}

private func recorded(_ value: JSONValue?) -> [String]? {
  guard case .array(let items)? = value else { return nil }
  let keys = items.compactMap(\.stringValue)
  return keys.count == items.count ? keys.map(\.precomposedStringWithCanonicalMapping) : nil
}

private func created(_ ref: EntityRef, in transaction: ReadTransaction) throws -> HLCTimestamp? {
  guard case .record(let record)? = try transaction.state(of: ref, scope: .vault) else { return nil }
  return record[field: "natural_key"]?.clock
}

private func planLearns(_ plan: OraclePlan?) -> String? {
  switch plan ?? .none {
  case .none: ChapterFingerprint.learns(ChapterContract())
  case .contract(let planned): ChapterFingerprint.learns(planned)
  case .unreadable: nil
  }
}

// Rule 2's exact shape, written out: nothing for chapter 1, else chapters up to N - 1 contiguously from chapter 1 or from a canon entry.
private func shaped(_ upstream: DraftUpstream, _ chapter: Int) -> Bool {
  let chapters = upstream.entries.map(\.chapter)
  guard chapter > 1 else { return chapters.isEmpty }
  guard let first = upstream.entries.first, chapters == Array(first.chapter..<chapter), first.chapter >= 1 else { return false }
  let rest = upstream.entries.dropFirst().allSatisfy { entry in
    if case .draft = entry { return true }
    return false
  }
  if case .canon = first { return rest }
  return rest && first.chapter == 1
}

// Rule 4 of ChapterFingerprint read as the reference's ledger leaves it: every pair at its earliest final or approved chapter, a manual row over any plan.
private func expectedKnowledge(
  _ novel: UUID, _ world: OracleNovel, _ lifecycle: [Int: ChapterLifecycleEntry], _ universe: ProjectionUniverse, in transaction: ReadTransaction,
  planWorld: NovelPlanWorld?
) throws -> Set<LedgerView> {
  guard let planWorld else { return [] }
  let liveFacts = Set(planWorld.facts.map(\.fact))
  let factByKey = Dictionary(planWorld.facts.map { ($0.fact, $0.disclosureFact) }) { first, _ in first }
  var liveEntities = Set<String>()
  for key in learners {
    if case .readable(let entry) = try EntityRecord.read(EntityRecord.ref(novel: novel, entity: key), in: transaction), !entry.isRemoved { liveEntities.insert(key) }
  }
  var manual = [String: LedgerView]()
  var retracted = Set<String>()
  for fact in factKeys {
    for entity in learners {
      switch try CharacterKnowledgeRecord.read(novel: novel, fact: fact, entity: entity, in: transaction) {
      case .readable(let entry) where entry.isRemoved: retracted.insert("\(fact) \(entity)")
      case .readable(let entry): manual["\(fact) \(entity)"] = LedgerView(fact, entity, entry.record.reveal.chapter, .manual, .committed)
      default: break
      }
    }
  }
  let contexts = plannedUnlockContexts(planWorld.planWorld, conditioned: true)
  var ledger = [String: LedgerView]()
  for chapter in universe.chapters {
    let taught: (ChapterContract, KnowledgeStatus, HLCTimestamp?)?
    if let final = world.finals[chapter] {
      taught = final.contract.map { ($0, .committed, final.clock) }
    } else if let approval = lifecycle[chapter]?.approval, case .contract(let planned)? = world.plans[chapter] {
      taught = (planned, .provisional, world.approvals[chapter]?.first { $0.record.id == approval }?.clock)
    } else {
      taught = nil
    }
    guard let (planned, status, since) = taught, let since, planned.pov.contains(where: { !$0.isEmpty }) else { continue }
    for learn in planned.reveals {
      let (fact, entity) = (learn.factKey.precomposedStringWithCanonicalMapping, learn.entityKey.precomposedStringWithCanonicalMapping)
      guard liveFacts.contains(fact), liveEntities.contains(entity), let found = factByKey[fact], disclosureRequirements(found, contexts(chapter)).isEmpty else { continue }
      let secretCreated = try created(SecretRecord.ref(novel: novel, secret: fact), in: transaction)
      let entityCreated = try created(EntityRecord.ref(novel: novel, entity: entity), in: transaction)
      guard let secretCreated, let entityCreated, secretCreated <= since, entityCreated <= since else { continue }
      if ledger["\(fact) \(entity)"] == nil { ledger["\(fact) \(entity)"] = LedgerView(fact, entity, chapter, .brief, status) }
    }
  }
  for key in retracted { ledger[key] = nil }
  for (key, row) in manual { ledger[key] = row }
  return Set(ledger.values.filter { liveFacts.contains($0.fact) && liveEntities.contains($0.entity) })
}

// provisional-knowledge.ts:141 read per secret from what each canon recorded: the lowest final chapter that recorded it while it was live, a live secret's `removed`
// clock being its last create or restore.
private func expectedDisclosure(_ novel: UUID, _ world: OracleNovel, _ universe: ProjectionUniverse, in transaction: ReadTransaction) throws
  -> (disclosed: [String: Int], seen: Set<String>)
{
  var disclosed = [String: Int]()
  var seen = Set<String>()
  for chapter in universe.chapters {
    guard let final = world.finals[chapter] else { continue }
    guard let keys = final.recorded, let written = final.finalized else {
      seen.insert("final without a set")
      continue
    }
    for key in keys where disclosed[key] == nil {
      let ref = SecretRecord.ref(novel: novel, secret: key)
      let state = try transaction.state(of: ref, scope: .vault)
      guard case .readable(let entry) = SecretRecord.reading(state, of: ref), !entry.isRemoved, case .record(let record)? = state,
        let since = record[field: "removed"]?.clock, since <= written
      else {
        seen.insert("recorded but not live then")
        continue
      }
      disclosed[key] = chapter
      seen.insert("disclosed")
    }
  }
  return (disclosed, seen)
}

final class ChapterCoverage: Sendable {
  let seen = Mutex(Set<String>())
}

private func oracle(_ coverage: ChapterCoverage) -> @Sendable (NovelForgeReconciler, VaultStore, ProjectionUniverse) async throws -> Void {
  { _, store, universe in
    for novel in universe.novels {
      let reveals = try await Projection.fetch(PlanRevealDerivation.request(for: novel), in: store)
      let (expected, knowledge, disclosure) = try await store.read { transaction in
        let world = try read(novel, universe, in: transaction, reveals: reveals)
        let lifecycle = expectedLifecycle(novel, world)
        let planWorld = try NovelPlanWorld.stored(for: novel, in: DerivationContext(records: transaction))
        return (
          lifecycle, try expectedKnowledge(novel, world, lifecycle, universe, in: transaction, planWorld: planWorld),
          try expectedDisclosure(novel, world, universe, in: transaction)
        )
      }
      let actual = try await ChapterTables.lifecycle(novel, in: store)
      guard actual == expected else { throw ProjectionPropertyFailure.oracle("lifecycle of \(novel): \(actual) differs from \(expected)") }
      let ledger = try await ChapterTables.knowledge(novel, in: store)
      guard ledger == knowledge else { throw ProjectionPropertyFailure.oracle("knowledge of \(novel): \(ledger) differs from \(knowledge)") }
      let disclosed = try await ChapterTables.disclosure(novel, in: store)
      guard disclosed == disclosure.disclosed else { throw ProjectionPropertyFailure.oracle("reader disclosure of \(novel): \(disclosed) differs from \(disclosure)") }
      let approvals = try await ChapterTables.approvals(novel, in: store)
      guard approvals == expected.compactMapValues(\.approval) else { throw ProjectionPropertyFailure.oracle("approvals in force of \(novel) differ") }

      var facts = Set(actual.values.compactMap { $0.review.map { "review \($0.rawValue)" } })
      facts.formUnion(actual.values.compactMap { $0.stale.map { "stale \($0.code)" } })
      facts.formUnion(actual.values.compactMap { $0.planStale.map { _ in "plan stale" } })
      facts.formUnion(actual.values.compactMap { $0.approvalKind.map { "approved \($0.rawValue)" } })
      facts.formUnion(actual.values.compactMap { entry in entry.stale == nil && entry.differences != nil ? "accepted" : nil })
      facts.formUnion(ledger.map { "knowledge \($0.source.rawValue) \($0.status.rawValue)" })
      facts.formUnion(disclosure.seen)
      coverage.seen.withLock { $0.formUnion(facts) }
    }
  }
}

@Suite("Chapter lifecycle projection property", TestTimeLimit.property)
struct ChapterPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndAgreeWithTheOracleOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      derivations: chapterAreaDerivations, operations: ChapterOperations.all + ChapterOperations.focused + ChapterOperations.recreating, iterations: 4, steps: 40,
      settled: oracle(ChapterCoverage()))
    try await property.check(order: order, seed: order == .causal ? 0xD21A : 0xD21B)
  }

  @Test(.enabled(if: ProjectionProperty.scale > 1, "a check of the generator, not of the derivations: NOVELFORGE_PROPERTY_SCALE=2 swift test"))
  func shouldReachEveryInterestingState() async throws {
    let coverage = ChapterCoverage()
    let unfinalized = ChapterOperations.all.filter { !$0.name.hasPrefix("finalize") && !$0.name.hasPrefix("purge") }
    try await withThrowingTaskGroup { group in
      let groups = [
        (ChapterOperations.all, 24, UInt64(0xD21C)), (unfinalized, 16, 0xD21D), (ChapterOperations.focused, 20, 0xD21E),
        (ChapterOperations.focused + ChapterOperations.recreating, 28, 0xE01A),
      ]
      for (operations, steps, seed) in groups {
        let property = ProjectionProperty(
          derivations: chapterAreaDerivations, operations: operations, iterations: 24, steps: steps, checksEveryStep: false, settled: oracle(coverage))
        group.addTask { try await property.check(order: .causal, seed: seed) }
      }
      try await group.waitForAll()
    }
    let expected: Set<String> = [
      "review needs_review", "review approved", "review final", "stale unrecorded", "stale draft", "stale knowledge", "stale canon", "stale reveal", "plan stale",
      "approved standard", "approved as_written", "accepted", "knowledge manual committed", "knowledge brief committed", "knowledge brief provisional",
      "disclosed", "recorded but not live then", "final without a set",
    ]
    #expect(expected.subtracting(coverage.seen.withLock { $0 }) == [])
  }

  @Test
  func shouldBeInTheStandardCatalogue() {
    for derivation in ChapterDerivations.all { #expect(NovelForgeDerivations.standard.contains { type(of: $0) == type(of: derivation) }) }
  }
}

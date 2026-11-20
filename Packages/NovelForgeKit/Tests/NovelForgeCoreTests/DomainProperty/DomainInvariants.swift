import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText

@testable import NovelForgeCore

/// The rules of the plan's "From database rule to native mechanism" table, judged on one settled replica: each derived row against an oracle computed from the
/// records directly, and the read models against both.
struct DomainInvariants {
  private final class Violations {
    var list: [String] = []
  }

  private let found = Violations()
  private let novel: UUID
  private let records: NovelRecords
  private let derived: NovelDerived
  private let chapters: [Int: ChapterOracle.State]

  private init(records: NovelRecords, derived: NovelDerived) {
    novel = records.novel
    self.records = records
    self.derived = derived
    let violated = Set(derived.reveals.filter { $0.value.status == .violated }.keys)
    chapters = ChapterOracle.states(records, violated: violated)
  }

  static func check(_ novels: [UUID], in transaction: ReadTransaction) throws -> [String] {
    var all = [String]()
    let stored = try NovelRecord.listing(in: transaction).entries.map(\.record.id)
    for novel in Set(novels + stored).sorted(by: { $0.uuidString < $1.uuidString }) {
      let invariants = DomainInvariants(records: try NovelRecords.read(novel, in: transaction), derived: try NovelDerived.read(novel, in: transaction.database))
      invariants.checkNaturalKeys()
      invariants.checkFinals()
      invariants.checkApprovals()
      invariants.checkKnowledge()
      invariants.checkMilestones()
      invariants.checkPlans()
      invariants.checkVolumes()
      invariants.checkNotebook()
      try invariants.checkReadModels(in: transaction)
      all += invariants.found.list
    }
    try DomainReadModelChecks.checkLibrary(in: transaction, into: &all)
    return all
  }

  private func expect(_ holds: Bool, _ rule: String, _ detail: @autoclosure () -> String = "") {
    guard !holds else { return }
    found.list.append("novel \(novel.uuidString.prefix(8)): \(rule)\(detail().isEmpty ? "" : " — \(detail())")")
  }

  // One final chapter, draft and plan per chapter number; unique keys for pages, entities, secrets, milestones, volumes, threads, mysteries and reveals.
  private func checkNaturalKeys() {
    for (kind, keys) in records.naturalKeys.sorted(by: { $0.key < $1.key }) {
      let duplicated = Dictionary(grouping: keys, by: \.key).filter { $0.value.count > 1 }.keys.sorted()
      expect(duplicated.isEmpty, "one \(kind) per natural key", duplicated.joined(separator: ", "))
      for key in keys { expect(key.stored == key.rebuilt, "a \(kind)'s id is the hash of its natural key", key.key) }
    }
  }

  // A chapter is final iff its canon exists; finals form a prefix; the story cursor is the first chapter that is not final; finalize binds the approval in force.
  private func checkFinals() {
    let canons = Set(records.finals.keys)
    expect(Set(derived.finals.map(\.chapter)) == canons, "the final set is the chapters with a canon", "\(derived.finals.map(\.chapter).sorted()) vs \(canons.sorted())")
    expect(derived.finals.allSatisfy(\.isReadable), "every canon is readable")
    expect(canons == Set(1..<(records.frontier + 1)), "finals form a prefix", "\(canons.sorted())")
    let expected = records.exists || !canons.isEmpty ? records.frontier + 1 : nil
    expect(
      derived.cursor?.chapter == expected, "the story cursor is the first chapter that is not final",
      "\(String(describing: derived.cursor?.chapter)) vs \(String(describing: expected))")
    for (chapter, entry) in derived.lifecycle {
      expect(entry.isFinal == canons.contains(chapter), "the lifecycle marks exactly the final chapters final", "chapter \(chapter)")
      expect((entry.review == .final) == entry.isFinal, "a chapter's review is final iff it is final", "chapter \(chapter)")
    }
    for final in derived.finals {
      guard let canon = records.finals[final.chapter]?.canon else { continue }
      expect(final.approval == canon.approval, "the final set names the canon's approval", "chapter \(final.chapter)")
      guard let named = canon.approval, let approval = records.approval(named)?.record else {
        expect(false, "a canon binds an approval that exists", "chapter \(final.chapter)")
        continue
      }
      expect(approval.chapter == final.chapter && approval.draftRevision == canon.draftRevision, "a canon binds an approval of the revision it holds", "chapter \(final.chapter)")
      expect(
        approval.approvalKind.known != nil && approval.planTermsDigest == ChapterFingerprint.planTerms(canon.contract), "a canon binds an approval of the contract it holds",
        "chapter \(final.chapter)")
    }
  }

  // A draft is stale exactly when something its head recorded differs and no as-written approval of the head accepted it, or its plan breaks the reveal rule;
  // the approval in force is the latest of a known kind naming the current draft head and the plan head's terms, on an unfinalized chapter without a stale mark.
  private func checkApprovals() {
    expect(Set(derived.lifecycle.keys) == Set(chapters.keys), "the lifecycle has a row per chapter with a canon, a live draft or a live plan")
    for (chapter, oracle) in chapters.sorted(by: { $0.key < $1.key }) {
      let entry = derived.lifecycle[chapter]
      let at = "chapter \(chapter)"
      expect(entry?.resting == oracle.resting, "a chapter rests on its canon's draft revision or its draft head", at)
      expect(entry?.taught == (oracle.isFinal ? nil : oracle.teaches), "an unfinalized chapter teaches its plan's learns only while an approval carries them", at)
      expect(
        entry?.stale.map(ChapterOracle.Cause.init) == oracle.stale, "a draft's stale mark and what changed is the first unaccepted difference from what it recorded",
        "\(at): \(String(describing: entry?.stale)) vs \(String(describing: oracle.stale))")
      expect(
        entry?.differences == oracle.digest, "a draft's differences are the digest of what it was written against and no longer matches",
        "\(at): \(String(describing: entry?.differences)) vs \(String(describing: oracle.digest))")
      let shown = "\(at): \(String(describing: derived.inForce[chapter]?.approval)) vs \(String(describing: oracle.inForce))"
      expect(derived.inForce[chapter]?.approval == oracle.inForce, "the approval in force names the current heads and matching plan terms", shown)
      expect(entry?.approval == oracle.inForce, "the lifecycle holds the approval in force", shown)
      expect(
        entry?.review == oracle.review, "a chapter is final, then generating while a generate job is open, then held by its head's latest judge review, then approved",
        "\(at): \(String(describing: entry?.review)) vs \(String(describing: oracle.review))")
    }
  }

  // Committed knowledge only from final chapters' canons, provisional only from approvals in force, each only for a pair whose fact and learner existed then.
  private func checkKnowledge() {
    let manual = Dictionary(records.manual.map { (NovelRecords.pair($0.fact, $0.entity), $0) }) { first, _ in first }
    let rows = Dictionary(derived.knowledge.map { (NovelRecords.pair($0.fact, $0.entity), $0) }) { first, _ in first }
    for (pair, reveal) in manual where records.secrets[reveal.fact] != nil && records.entities.contains(reveal.entity) {
      let row = rows[pair]
      expect(row?.source == .manual && row?.chapter == reveal.reveal.chapter && row?.status == .committed, "a manual reveal of live records is ledgered as written", pair)
    }
    for row in derived.knowledge {
      let pair = NovelRecords.pair(row.fact, row.entity)
      expect(records.secrets[row.fact] != nil && records.entities.contains(row.entity), "a knowledge row names a live secret and a live entity", pair)
      guard row.source != .manual else {
        expect(manual[pair] != nil, "a manual knowledge row has a live manual reveal", pair)
        continue
      }
      expect(row.source == .brief, "a derived knowledge row comes from a plan contract", pair)
      expect(manual[pair] == nil && !records.retracted.contains(pair), "a retracted or manual pair is never ledgered from a contract", pair)
      guard let (contract, cutoff, revision, status) = contributor(of: row.chapter) else {
        expect(false, "a contract row's chapter is final or has an approval in force", "\(pair) in chapter \(row.chapter)")
        continue
      }
      expect(row.status == status, "a final chapter's knowledge is committed and an approved one's provisional", "\(pair) in chapter \(row.chapter)")
      expect(row.draftRevision == revision, "a contract row names the revision its chapter rests on", pair)
      if let frozen = frozenKnowledge(of: row.chapter) {
        expect(frozen.contains(pair), "a final chapter that recorded its knowledge commits only the pairs it recorded", "\(pair) in chapter \(row.chapter)")
      } else {
        if let fact = records.secrets[row.fact] {
          expect(isRevealed(fact, at: row.chapter), "a ledgered fact is revealed by the chapter that ledgers it", "\(pair) in chapter \(row.chapter)")
        }
        let taught = contract.pov.contains { !$0.isEmpty } && contract.reveals.contains { $0.factKey == row.fact && $0.entityKey == row.entity }
        expect(taught, "a contract row is taught by its chapter's contract", "\(pair) in chapter \(row.chapter)")
      }
      let fact = records.liveSince[SecretRecord.ref(novel: novel, secret: row.fact)]
      let learner = records.liveSince[EntityRecord.ref(novel: novel, entity: row.entity)]
      let existed = cutoff.map { cutoff in fact.map { $0 <= cutoff } == true && learner.map { $0 <= cutoff } == true } ?? false
      expect(existed, "knowledge is ledgered only for a fact and a learner live since the bound approval or earlier", "\(pair) in chapter \(row.chapter)")
    }
    for (pair, (chapter, status)) in requiredKnowledge(manual: Set(manual.keys)).sorted(by: { $0.key < $1.key }) {
      let row = rows[pair]
      expect(
        row?.source == .brief && row?.chapter == chapter && row?.status == status, "every revealable learn of a contributing chapter is ledgered at the earliest",
        "\(pair) in chapter \(chapter)")
    }
  }

  /// The rows the ledger must hold: for each final chapter and chapter with an approval in force, ascending, each learn of its POV contract whose fact is
  /// live and revealed by then, whose learner is live, both live since the cutoff or earlier, and not manual, retracted or ledgered earlier.
  private func requiredKnowledge(manual: Set<String>) -> [String: (Int, KnowledgeStatus)] {
    var required = [String: (Int, KnowledgeStatus)]()
    for chapter in chapters.keys.sorted() {
      guard let (contract, cutoff, _, status) = contributor(of: chapter), let cutoff else { continue }
      let frozen = frozenKnowledge(of: chapter)
      guard frozen != nil || contract.pov.contains(where: { !$0.isEmpty }) else { continue }
      let learns = records.finals[chapter]?.canon.knowledge ?? contract.reveals
      for learn in learns {
        let pair = NovelRecords.pair(learn.factKey, learn.entityKey)
        guard let fact = records.secrets[learn.factKey], records.entities.contains(learn.entityKey), frozen != nil || isRevealed(fact, at: chapter) else { continue }
        let live = [SecretRecord.ref(novel: novel, secret: learn.factKey), EntityRecord.ref(novel: novel, entity: learn.entityKey)].map { records.liveSince[$0] }
        guard live.allSatisfy({ $0.map { $0 <= cutoff } == true }), !manual.contains(pair), !records.retracted.contains(pair), required[pair] == nil else { continue }
        required[pair] = (chapter, status)
      }
    }
    return required
  }

  /// E04 with G26: a final chapter's canon records the pairs its finalizing device committed, which the reveal rule is not asked about again.
  private func frozenKnowledge(of chapter: Int) -> Set<String>? {
    records.finals[chapter]?.canon.knowledge.map { Set($0.map { NovelRecords.pair($0.factKey, $0.entityKey) }) }
  }

  private func contributor(of chapter: Int) -> (ChapterContract, HLCTimestamp?, String?, KnowledgeStatus)? {
    if let final = records.finals[chapter] {
      let clock = derived.finals.first { $0.chapter == chapter }?.canonClock
      let approval = final.canon.approval.flatMap(records.approval)?.clock
      let cutoff = approval.map { approval in clock.map { min($0, approval) } ?? approval }
      return (final.canon.contract, cutoff, final.canon.draftRevision, .committed)
    }
    guard let held = chapters[chapter]?.inForce, let approval = records.approval(held) else { return nil }
    return (records.plans[chapter] ?? ChapterContract(), approval.clock, approval.record.draftRevision, .provisional)
  }

  // A milestone is claimed by at most one chapter: the earliest final chapter's claim, else the earliest plan's; every other claim is flagged.
  private func checkMilestones() {
    var claims = [String: (canon: [Int], plan: [Int])]()
    var expected = Set<String>()
    for chapter in records.worldChapters {
      for key in records.contract(of: chapter)?.claimedMilestones ?? [] {
        if records.finals[chapter] != nil { claims[key, default: ([], [])].canon.append(chapter) } else { claims[key, default: ([], [])].plan.append(chapter) }
      }
    }
    for chapter in records.worldChapters {
      for key in records.contract(of: chapter)?.claimedMilestones ?? [] {
        let holder = records.milestones.contains(key) ? claims[key].flatMap { $0.canon.min() ?? $0.plan.min() } : nil
        let status: MilestoneClaimStatus = holder == nil ? .unknown : holder == chapter ? .holds : .duplicate
        expected.insert(Self.claim(key, chapter, records.finals[chapter] == nil ? .plan : .canon, status, holder))
      }
    }
    let rows = Set(derived.claims.map { Self.claim($0.milestone, $0.chapter, $0.basis, $0.status, $0.holder) })
    expect(rows == expected, "the earliest claim holds and later duplicates are flagged", "\(rows.sorted()) vs \(expected.sorted())")
    for key in records.milestones {
      expect(derived.claims.filter { $0.milestone == key && $0.status == .holds }.count <= 1, "at most one claim of a milestone holds", key)
    }
    let states = Set(
      records.milestones.map { key in
        let tally = claims[key]
        let state: MilestoneState = tally?.canon.isEmpty == false ? .reached : tally?.plan.isEmpty == false ? .planned : .open
        return "\(key) \(state.rawValue) \(String(describing: tally?.canon.min() ?? tally?.plan.min())) \(String(describing: tally?.canon.min()))"
      })
    let stored = Set(derived.milestoneStates.map { "\($0.milestone) \($0.state.rawValue) \(String(describing: $0.plannedChapter)) \(String(describing: $0.reachedChapter))" })
    expect(stored == states, "a milestone's state follows its holding claim", "\(stored.sorted()) vs \(states.sorted())")
  }

  private static func claim(_ key: String, _ chapter: Int, _ basis: ClaimBasis, _ status: MilestoneClaimStatus, _ holder: Int?) -> String {
    "\(key)@\(chapter) \(basis.rawValue) \(status.rawValue) \(String(describing: holder))"
  }

  // One verdict per live plan, only plans after the latest final chapter judged; rival endings resolve to the latest and are flagged.
  private func checkPlans() {
    expect(Set(derived.reveals.keys) == Set(records.plans.keys), "a reveal verdict per live plan", "\(derived.reveals.keys.sorted()) vs \(records.plans.keys.sorted())")
    let latest = records.worldChapters.filter { records.contract(of: $0)?.isEnding == true }.max()
    for (chapter, verdict) in derived.reveals {
      expect((verdict.status == .settled) == (chapter <= records.frontier), "only a plan after the latest final chapter is judged", "chapter \(chapter)")
      let expected = records.contract(of: chapter)?.isEnding == true && chapter != latest ? latest : nil
      expect(verdict.rivalEnding == expected, "a rival ending is flagged and resolved to the latest", "chapter \(chapter): \(String(describing: verdict.rivalEnding))")
      guard chapter > records.frontier, let plan = records.plans[chapter] else { continue }
      let breaks = breaksRevealRule(plan, at: chapter)
      expect(verdict.status == (breaks ? .violated : .holds), "a plan teaching a fact before it is revealed breaks the reveal rule", "chapter \(chapter): \(verdict.status)")
    }
  }

  private func breaksRevealRule(_ plan: ChapterContract, at chapter: Int) -> Bool {
    guard plan.pov.contains(where: { !$0.isEmpty }) else { return false }
    return plan.reveals.contains { learn in records.secrets[learn.factKey].map { !isRevealed($0, at: chapter) } ?? false }
  }

  /// A fact is revealed at a chapter once its reveal chapter, if any, has come and, if it has an unlock condition, every milestone it names has been claimed by
  /// a chapter up to that one, a final chapter's canon or a plan, the chapter's own claims included (reveal-rule.ts:66); a seed without a condition always is.
  private func isRevealed(_ fact: SecretRecord, at chapter: Int) -> Bool {
    let dated = fact.revealChapter.map { $0 <= chapter }
    switch fact.unlock {
    case nil, .null?:
      return fact.source == .known(.seed) || dated == true
    case let unlock?:
      guard let keys = Self.milestones(of: unlock) else {
        expect(false, "the universe writes only milestone unlock conditions", fact.secret)
        return false
      }
      let reached = Set(records.worldChapters.filter { $0 <= chapter }.flatMap { records.contract(of: $0)?.claimedMilestones ?? [] })
      return dated != false && keys.allSatisfy(reached.contains)
    }
  }

  private static func milestones(of unlock: JSONValue) -> [String]? {
    guard let terms = unlock.objectValue?["all"]?.arrayValue else { return nil }
    let keys = terms.compactMap { $0.objectValue?["milestone"]?.stringValue }
    return keys.count == terms.count ? keys : nil
  }

  // The active volume is the first unmet one after the last met one, in (ordinal, key) order; at most one is active.
  private func checkVolumes() {
    let ordered = records.volumes.sorted { ($0.ordinal, JSString($0.volume)) < ($1.ordinal, JSString($1.volume)) }
    let passed = (ordered.lastIndex { $0.goalMet } ?? -1) + 1
    let active = ordered.indices.first { $0 >= passed && !ordered[$0].goalMet }
    let expected = Set(
      ordered.enumerated().map { index, volume in
        let state: VolumeState = volume.goalMet ? .goalMet : index == active ? .active : .notStarted
        return "\(volume.volume) \(volume.ordinal) \(state.rawValue)"
      })
    let rows = Set(derived.volumes.map { "\($0.volume) \($0.ordinal) \($0.state.rawValue)" })
    expect(rows == expected, "the active volume derivation", "\(rows.sorted()) vs \(expected.sorted())")
    expect(derived.volumes.filter { $0.state == .active }.count <= 1, "at most one volume is active")
  }

  // One successor per Notebook entry: of entries superseding the same one the latest succeeds it and every earlier sibling; a withdrawal labels over that.
  private func checkNotebook() {
    let ids = Set(records.entries.map(\.record.id))
    var children = [UUID: [AppendedEntry<NotebookEntryRecord>]]()
    for entry in records.entries {
      guard let target = entry.record.supersedes, target != entry.record.id, ids.contains(target) else { continue }
      children[target, default: []].append(entry)
    }
    var claimants = [UUID: [AppendedEntry<NotebookEntryRecord>]]()
    for (target, group) in children {
      guard let latest = group.last else { continue }
      for claimed in [target] + group.dropLast().map(\.record.id) { claimants[claimed, default: []].append(latest) }
    }
    var withdrawals = [UUID: UUID]()
    for appended in records.withdrawals where ids.contains(appended.record.entry) && withdrawals[appended.record.entry] == nil {
      withdrawals[appended.record.entry] = appended.record.id
    }
    expect(Set(derived.notebook.keys) == ids, "a Notebook state per entry")
    for entry in records.entries {
      let id = entry.record.id
      let successor = claimants[id]?.max { NotebookEntryRecord.chronologically($0, $1) }?.record.id
      let status: LedgerEntryStatus = withdrawals[id] != nil ? .withdrawn : successor == nil ? .active : .superseded
      let row = derived.notebook[id]
      expect(
        row?.successor == successor && row?.status == status, "the latest of concurrent supersedes succeeds the entry",
        "\(id.uuidString.prefix(8)) \(String(describing: row?.status))")
      expect(row?.withdrawal == withdrawals[id], "the earliest withdrawal of an entry labels it", "\(id.uuidString.prefix(8)) \(String(describing: row?.withdrawal))")
    }
    for (target, group) in children {
      let active = group.filter { derived.notebook[$0.record.id]?.status == .active }
      expect(active.count <= 1 && active.allSatisfy { $0 == group.last }, "at most the latest entry superseding another stays active", target.uuidString)
    }
  }

  private func checkReadModels(in transaction: ReadTransaction) throws {
    let expectations = DomainReadModelChecks.Expected(
      frontier: records.frontier, finals: Set(records.finals.keys), approvals: derived.inForce.mapValues(\.approval),
      lifecycle: Set(derived.lifecycle.keys), activeVolume: derived.volumes.first { $0.state == .active }?.volume, milestones: records.milestones.count,
      duplicates: Dictionary(grouping: derived.claims.filter { $0.status == .duplicate }, by: \.milestone).mapValues { $0.map(\.chapter).sorted() },
      volumes: Dictionary(uniqueKeysWithValues: derived.volumes.map { ($0.volume, $0.state) }), secrets: records.secrets.count, promises: records.promises,
      pages: records.pages, entities: records.entities.count, notebook: Dictionary(grouping: derived.notebook.values, by: \.status).mapValues(\.count),
      shownEntries: records.entries.filter { derived.notebook[$0.record.id]?.status == .active && NotebookTopics.isVisibleInNotebook($0.record.topic) }.count,
      knowledge: Set(derived.knowledge), reviews: chapters.mapValues(\.review))
    found.list += try DomainReadModelChecks.check(novel, expecting: expectations, in: transaction).map { "novel \(novel.uuidString.prefix(8)): \($0)" }
  }
}

import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let checklistNovel = UUID()

private enum ChecklistWorld {
  static func store() async throws -> VaultStore {
    let store = try ReadWorld.store(allowingFaults: true)
    try await ReadWorld.write(store) { transaction in
      _ = try NovelRecord(id: checklistNovel, name: "Ember", premise: "A keeper of tides.", theme: "  ", endingQuestion: "Does she leave?").create(in: &transaction)
      _ = try VolumeRecord(novel: checklistNovel, volume: "b", ordinal: 2, objective: "Later").create(in: &transaction)
      _ = try VolumeRecord(novel: checklistNovel, volume: "a", ordinal: 1, objective: "Reach the coast").create(in: &transaction)
    }
    return store
  }

  static func checklist(_ store: VaultStore, novel: UUID = checklistNovel) async throws -> Checklist {
    try #require(try await store.load(ProgressChecklist.self, novel).checklist.value?.checklist)
  }

  static func item(_ key: ProgressItemKey, in store: VaultStore) async throws -> ChecklistItem? {
    try await checklist(store).items.first { $0.key == key }
  }

  static func override(_ key: String, _ status: String, kind: LedgerEntryKind = .system) -> NewNotebookEntry {
    NewNotebookEntry(kind: kind, topic: "progress.\(key)", statement: "Override.", decidedBy: .system, payload: .object(["status": .string(status)]))
  }

  static func active(at topic: String, in store: VaultStore) async throws -> [NotebookEntry] {
    let history = try #require(try await store.load(NotebookHistory.self, checklistNovel).notebook.value)
    return history.ledger.active(matching: NotebookFilter(topics: [topic]))
  }

  static func statuses(_ checklist: Checklist) -> [String] {
    checklist.items.map { "\($0.key.rawValue)=\($0.status.rawValue)" }
  }
}

@Suite("Progress checklist read model", .timeLimit(.minutes(3)))
struct ProgressChecklistTests {
  // apps/novel-forge-server/src/common/progress.ts:73,125
  @Test func shouldAnswerFromTheNovelTheFirstVolumeAndTheNextChapterPlan() async throws {
    let store = try await ChecklistWorld.store()
    #expect(
      ChecklistWorld.statuses(try await ChecklistWorld.checklist(store)) == [
        "premise=answered", "protagonist=open", "opposition=open", "theme=open", "reader_promise=open", "ending=answered", "first_volume_goal=answered",
        "next_chapter_planned=open",
      ])
    #expect(try await ChecklistWorld.checklist(store).items.first?.label == "Premise")
    try await ReadWorld.write(store) { transaction in try PlanWorldWrites.putPlan(novel: checklistNovel, chapter: 1, planContent(contract(pov: [])), in: &transaction) }
    #expect(try await ChecklistWorld.item(.nextChapterPlanned, in: store)?.status == .answered)
  }

  // next-chapter.ts:11 and batch-selection.ts:19: a chapter with a draft is written, so the item stops applying
  @Test func shouldDropTheNextChapterItemOnceChapterOneHasADraft() async throws {
    let store = try await ChecklistWorld.store()
    try await ReadWorld.write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: checklistNovel, chapter: 1, planContent(contract(pov: [])), in: &transaction)
      _ = try ChapterWrites.draft(novel: checklistNovel, chapter: 1, in: &transaction)
    }
    #expect(try await ChecklistWorld.item(.nextChapterPlanned, in: store) == nil)
  }

  @Test func shouldNotConsultALaterPlanWhileChapterOneIsUndrafted() async throws {
    let store = try await ChecklistWorld.store()
    try await ReadWorld.write(store) { transaction in try PlanWorldWrites.putPlan(novel: checklistNovel, chapter: 2, planContent(contract(pov: [])), in: &transaction) }
    #expect(try await ChecklistWorld.item(.nextChapterPlanned, in: store)?.status == .open)
  }

  @Test func shouldLeaveTheChecklistUnavailableOnALifecycleFault() async throws {
    let store = try await ChecklistWorld.store()
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    #expect(try await store.load(ProgressChecklist.self, checklistNovel).checklist.isUnavailable)
  }

  // plan-state.ts:94: a plan whose reveal no longer holds is not a plan for the checklist
  @Test func shouldNotCountANextChapterPlanThatBreaksTheRevealRule() async throws {
    let store = try await ChecklistWorld.store()
    try await ReadWorld.write(store) { transaction in
      try ChapterWrites.entity(novel: checklistNovel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: checklistNovel, "heir", revealChapter: 3, in: &transaction)
      try PlanWorldWrites.putPlan(novel: checklistNovel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
    }
    #expect(try await ChecklistWorld.item(.nextChapterPlanned, in: store)?.status == .open)
  }

  // progress.ts:30,101 and new-novel.service.ts:70: the latest active override wins over the answer
  @Test func shouldApplyTheLatestActiveOverrideAndNameItsEntry() async throws {
    let store = try await ChecklistWorld.store()
    let latest = try await store.write { transaction -> UUID in
      _ = try Notebook.record(ChecklistWorld.override("theme", "dismissed"), novel: checklistNovel, in: &transaction)
      return try Notebook.record(ChecklistWorld.override("theme", "undecided"), novel: checklistNovel, in: &transaction).id
    }
    let dismissed = try await store.write { transaction in
      _ = try Notebook.record(ChecklistWorld.override("premise", "dismissed", kind: .direction), novel: checklistNovel, in: &transaction)
      _ = try Notebook.record(ChecklistWorld.override("protagonist", "maybe"), novel: checklistNovel, in: &transaction)
      return try Notebook.record(ChecklistWorld.override("opposition", "dismissed"), novel: checklistNovel, in: &transaction).id
    }
    let theme = try #require(try await ChecklistWorld.item(.theme, in: store))
    #expect(theme.status == .undecided)
    #expect(theme.overrideEntry == latest)
    #expect(try await ChecklistWorld.item(.opposition, in: store)?.overrideEntry == dismissed)
    #expect(try await ChecklistWorld.item(.premise, in: store)?.status == .answered)
    #expect(try await ChecklistWorld.item(.protagonist, in: store)?.status == .open)
    _ = try await store.write { transaction in try Notebook.withdraw(latest, reason: "cleared", novel: checklistNovel, in: &transaction) }
    #expect(try await ChecklistWorld.item(.theme, in: store)?.status == .dismissed)
  }

  @Test func shouldDropTheNextChapterItemOnceChapterOneIsFinal() async throws {
    let store = try await ReadWorld.seeded()
    let checklist = try await ChecklistWorld.checklist(store, novel: readNovel)
    #expect(!checklist.items.contains { $0.key == .nextChapterPlanned })
  }

  @Test func shouldTellAMissingNovelFromAnUnreadableOne() async throws {
    let store = try await ChecklistWorld.store()
    #expect(try await store.load(ProgressChecklist.self, UUID()).checklist == .available(.missing))
    let unreadable = UUID()
    try await Projection.set(NovelForgeKey.novel(unreadable), ["archived": .bool(false)], in: store)
    #expect(try await store.load(ProgressChecklist.self, unreadable).checklist == .available(.unreadable))
  }

  // platform/apps/novel-forge-web/src/features/chat/chat-view.ts:379; the percentages are Math.round's for one to eight visible items
  @Test func shouldSummariseVisibleSettledAndDismissedItemsLikeTheWebChecklist() {
    func item(_ status: ProgressStatus) -> ChecklistItem { ChecklistItem(key: .premise, label: "", why: "", status: status, overrideEntry: nil) }
    let checklist = Checklist(items: [item(.answered), item(.undecided), item(.open), item(.dismissed), item(.open), item(.open)])
    #expect(checklist.visible.count == 5)
    #expect(checklist.settled == 2)
    #expect(checklist.dismissed == 1)
    #expect(!checklist.isComplete)
    let reference = [
      0, 100, 0, 50, 100, 0, 33, 67, 100, 0, 25, 50, 75, 100, 0, 20, 40, 60, 80, 100, 0, 17, 33, 50, 67, 83, 100, 0, 14, 29, 43, 57, 71, 86, 100, 0, 13, 25, 38, 50, 63, 75, 88,
      100,
    ]
    let percents = (1...8).flatMap { shown in
      (0...shown).map { settled in Checklist(items: Array(repeating: item(.answered), count: settled) + Array(repeating: item(.open), count: shown - settled)).percent }
    }
    #expect(percents == reference)
    #expect(Checklist(items: [item(.dismissed)]).percent == 100)
    #expect(Checklist(items: [item(.dismissed)]).isComplete)
  }
}

@Suite("Checklist overrides", .timeLimit(.minutes(3)))
struct ChecklistOverrideTests {
  // new-novel.service.ts:81-88
  @Test func shouldRecordAFirstOverrideAsASystemEntry() async throws {
    let store = try await ChecklistWorld.store()
    let entry = try await store.write { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    #expect(entry.topic == "progress.theme")
    #expect(entry.statement == "Marked undecided for now.")
    #expect(entry.entryKind == .known(.system))
    #expect(entry.decidedBy == .known(.system))
    #expect(entry.payload == .object(["status": .string("undecided")]))
    #expect(entry.supersedes == nil)
    let theme = try #require(try await ChecklistWorld.item(.theme, in: store))
    #expect(theme.status == .undecided)
    #expect(theme.overrideEntry == entry.id)
  }

  @Test func shouldSupersedeTheOverrideInForceAndWithdrawTheOthersAtItsTopic() async throws {
    let store = try await ChecklistWorld.store()
    let (stray, inForce) = try await store.write { transaction -> (UUID, UUID) in
      let stray = try Notebook.record(ChecklistWorld.override("theme", "maybe"), novel: checklistNovel, in: &transaction).id
      let inForce = try Notebook.record(ChecklistWorld.override("theme", "undecided"), novel: checklistNovel, in: &transaction).id
      _ = try Notebook.record(ChecklistWorld.override("theme", "unknown"), novel: checklistNovel, in: &transaction)
      return (stray, inForce)
    }
    let successor = try await store.write { transaction in try ChecklistOverrides.set(.theme, to: .dismissed, novel: checklistNovel, in: &transaction) }
    #expect(successor.supersedes == inForce)
    #expect(successor.statement == "Dismissed from the checklist.")
    #expect(try await ChecklistWorld.active(at: "progress.theme", in: store).map(\.id) == [successor.id])
    let history = try #require(try await store.load(NotebookHistory.self, checklistNovel).notebook.value)
    let withdrawn = try #require(history.entry(stray))
    #expect(withdrawn.status == .withdrawn)
    #expect(history.reason(for: withdrawn) == ChecklistOverrides.replacedReason)
    #expect(try await ChecklistWorld.item(.theme, in: store)?.status == .dismissed)
  }

  @Test func shouldWriteAgainWhenTheStatusIsUnchanged() async throws {
    let store = try await ChecklistWorld.store()
    let first = try await store.write { transaction in try ChecklistOverrides.set(.ending, to: .dismissed, novel: checklistNovel, in: &transaction) }
    let second = try await store.write { transaction in try ChecklistOverrides.set(.ending, to: .dismissed, novel: checklistNovel, in: &transaction) }
    #expect(second.supersedes == first.id)
    #expect(try await ChecklistWorld.item(.ending, in: store)?.overrideEntry == second.id)
  }

  // new-novel.service.ts:90-96
  @Test func shouldClearByWithdrawingEveryActiveEntryAtTheExactTopic() async throws {
    let store = try await ChecklistWorld.store()
    let ids = try await store.write { transaction -> [UUID] in
      [
        try Notebook.record(ChecklistWorld.override("theme", "dismissed"), novel: checklistNovel, in: &transaction).id,
        try Notebook.record(ChecklistWorld.override("theme", "undecided"), novel: checklistNovel, in: &transaction).id,
      ]
    }
    let other = try await store.write { transaction in try ChecklistOverrides.set(.readerPromise, to: .dismissed, novel: checklistNovel, in: &transaction) }
    try await store.write { transaction in try ChecklistOverrides.clear(.theme, novel: checklistNovel, in: &transaction) }
    let history = try #require(try await store.load(NotebookHistory.self, checklistNovel).notebook.value)
    for id in ids {
      let entry = try #require(history.entry(id))
      #expect(entry.status == .withdrawn)
      #expect(history.reason(for: entry) == "the author cleared the checklist override")
    }
    #expect(history.entry(other.id)?.status == .active)
    #expect(try await ChecklistWorld.item(.theme, in: store)?.status == .open)
  }

  @Test func shouldClearNothingWhenNoOverrideIsActive() async throws {
    let store = try await ChecklistWorld.store()
    let before = try #require(try await store.load(NotebookHistory.self, checklistNovel).notebook.value)
    try await store.write { transaction in try ChecklistOverrides.clear(.theme, novel: checklistNovel, in: &transaction) }
    #expect(try await store.load(NotebookHistory.self, checklistNovel).notebook.value == before)
  }

  @Test func shouldRefuseAnOverrideForAMissingNovel() async throws {
    let store = try await ChecklistWorld.store()
    let missing = UUID()
    do {
      _ = try await store.write { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: missing, in: &transaction) }
      Issue.record("the override should be refused")
    } catch {
      guard case .aborted(let cause) = error, let refusal = cause as? NotebookError else {
        Issue.record("unexpected error \(error)")
        return
      }
      #expect(refusal.code == "PRJ_001")
    }
  }
}

private func makeReplicas(seed: UInt64) async throws -> CausalReplicas {
  let reconciler = try Projection.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in try NovelRecord(id: checklistNovel, name: "Ember").create(in: &transaction) }
  try await replicas.settle()
  return replicas
}

private func expectEveryReplica(
  _ replicas: CausalReplicas, theme status: ProgressStatus, entry: UUID?, active: Int, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  for index in 0..<replicas.count {
    let store = await replicas.store(index)
    let theme = try await ChecklistWorld.item(.theme, in: store)
    #expect(theme?.status == status, sourceLocation: sourceLocation)
    #expect(theme?.overrideEntry == entry, sourceLocation: sourceLocation)
    #expect(try await ChecklistWorld.active(at: "progress.theme", in: store).count == active, sourceLocation: sourceLocation)
  }
}

@Suite("Checklist override replicas", .timeLimit(.minutes(2)))
struct ChecklistOverrideReplicaTests {
  @Test func shouldKeepTheLaterOfTwoConcurrentSetsOverTheSameOverride() async throws {
    let replicas = try await makeReplicas(seed: 0xC4E1)
    _ = try await replicas.write(0) { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    _ = try await replicas.write(1) { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(30))
    let later = try await replicas.write(2) { transaction in try ChecklistOverrides.set(.theme, to: .dismissed, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    try await expectEveryReplica(replicas, theme: .dismissed, entry: later.id, active: 1)
  }

  @Test func shouldKeepAConcurrentSetOverAClearOfTheEntryItReplaced() async throws {
    let replicas = try await makeReplicas(seed: 0xC4E2)
    _ = try await replicas.write(0) { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    let set = try await replicas.write(1) { transaction in try ChecklistOverrides.set(.theme, to: .dismissed, novel: checklistNovel, in: &transaction) }
    try await replicas.write(2) { transaction in try ChecklistOverrides.clear(.theme, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    try await expectEveryReplica(replicas, theme: .dismissed, entry: set.id, active: 1)
  }

  @Test func shouldKeepAConcurrentSetOverAClearWithTheLaterClock() async throws {
    let replicas = try await makeReplicas(seed: 0xC4E4)
    _ = try await replicas.write(0) { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    let set = try await replicas.write(1) { transaction in try ChecklistOverrides.set(.theme, to: .dismissed, novel: checklistNovel, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(30))
    try await replicas.write(2) { transaction in try ChecklistOverrides.clear(.theme, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    try await expectEveryReplica(replicas, theme: .dismissed, entry: set.id, active: 1)
  }

  @Test func shouldNameTheLaterOfTwoFirstSetsAndClearBothAfterwards() async throws {
    let replicas = try await makeReplicas(seed: 0xC4E3)
    _ = try await replicas.write(1) { transaction in try ChecklistOverrides.set(.theme, to: .dismissed, novel: checklistNovel, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(30))
    let later = try await replicas.write(2) { transaction in try ChecklistOverrides.set(.theme, to: .undecided, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    try await expectEveryReplica(replicas, theme: .undecided, entry: later.id, active: 2)
    try await replicas.write(0) { transaction in try ChecklistOverrides.clear(.theme, novel: checklistNovel, in: &transaction) }
    try await replicas.settle()
    try await expectEveryReplica(replicas, theme: .open, entry: nil, active: 0)
  }
}

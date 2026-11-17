import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("StoryModel")
struct StoryModelTests {
  private struct Fixture {
    let model: StoryModel
    let store: VaultStore
    let novel: UUID
    let task: Task<Void, Never>
  }

  private func makeFixture() async throws -> Fixture {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let model = StoryModel(context: NovelContext(store: store, novel: novel))
    let task = Task { await model.observe() }
    let fixture = Fixture(model: model, store: store, novel: novel, task: task)
    try await waitUntil { model.structure.value != nil && model.ledger.value != nil && model.bible.value != nil }
    return fixture
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the story to update")
  }

  private func volumeKeys(_ model: StoryModel) -> [String]? {
    model.structure.value?.volumes.value?.items.map(\.record.volume)
  }

  private func activeKey(_ model: StoryModel) -> String? {
    model.structure.value?.volumes.value?.items.first { $0.state == .active }?.record.volume
  }

  private func addVolumes(_ keys: [String], to model: StoryModel) async throws {
    for key in keys { try await model.createVolume(key: key, title: key.uppercased(), objective: "", body: "") }
    try await waitUntil { volumeKeys(model)?.count == keys.count }
  }

  @Test("should list volumes in creation order and activate the first")
  func listsVolumes() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    try await addVolumes(["a", "b", "c"], to: fixture.model)

    #expect(volumeKeys(fixture.model) == ["a", "b", "c"])
    #expect(activeKey(fixture.model) == "a")
    #expect(fixture.model.structure.value?.volumes.value?.items.first?.displayName == "A")
  }

  @Test("should move the active volume when volumes are reordered")
  func reorderMovesActiveVolume() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b", "c"], to: fixture.model)

    await fixture.model.moveVolume("c", by: -1)
    try await waitUntil { volumeKeys(fixture.model) == ["a", "c", "b"] }
    await fixture.model.moveVolume("c", by: -1)
    try await waitUntil { volumeKeys(fixture.model) == ["c", "a", "b"] }
    try await waitUntil { activeKey(fixture.model) == "c" }

    await fixture.model.moveVolumes(from: IndexSet(integer: 0), to: 3)
    try await waitUntil { volumeKeys(fixture.model) == ["a", "b", "c"] }
    try await waitUntil { activeKey(fixture.model) == "a" }
    #expect(fixture.model.failure == nil)
  }

  @Test("should ignore a move past either end of the volumes")
  func moveBeyondEdgesIsIgnored() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b"], to: fixture.model)

    await fixture.model.moveVolume("a", by: -1)
    await fixture.model.moveVolume("b", by: 1)

    #expect(volumeKeys(fixture.model) == ["a", "b"])
    #expect(fixture.model.failure == nil)
  }

  @Test("should mark the active goal met and activate the next volume")
  func goalMetAdvances() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b"], to: fixture.model)

    #expect(fixture.model.volumeActivated(afterMarking: "a") == "B")
    #expect(fixture.model.volumeActivated(afterMarking: "b") == nil)

    await fixture.model.markGoalMet("a")

    #expect(fixture.model.advance?.completed == "A")
    #expect(fixture.model.advance?.activated == "B")
    try await waitUntil { activeKey(fixture.model) == "b" }
    #expect(fixture.model.structure.value?.volume("a")?.state == .goalMet)
  }

  @Test("should show a localized error when the goal of a volume that is not active is marked met")
  func goalMetRefusal() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b"], to: fixture.model)

    await fixture.model.markGoalMet("b")

    #expect(fixture.model.advance == nil)
    #expect(fixture.model.failure?.error.headline == String(localized: "Only the active volume's goal can be marked met.", table: "Story"))
    #expect(fixture.model.failure?.error.detail == "VOL_003")
  }

  @Test("should show a localized error when a volume key is reused")
  func duplicateVolumeRefusal() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a"], to: fixture.model)

    do {
      try await fixture.model.createVolume(key: "a", title: "", objective: "", body: "")
      Issue.record("expected the duplicate to be refused")
    } catch {
      let presented = PresentedError(error, known: StoryErrors.headline)
      #expect(presented.headline == String(localized: "A volume with this key already exists.", table: "Story"))
    }
  }

  @Test("should remove a volume and bring it back from the recently removed list")
  func removeAndRestoreVolume() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b"], to: fixture.model)
    let first = try #require(fixture.model.structure.value?.volume("a"))

    await fixture.model.removeVolume(first)
    try await waitUntil { volumeKeys(fixture.model) == ["b"] }

    #expect(fixture.model.restorable == [.volume(key: "a", name: "A")])
    #expect(activeKey(fixture.model) == "b")

    await fixture.model.restore(try #require(fixture.model.restorable.first))
    try await waitUntil { volumeKeys(fixture.model) == ["a", "b"] }
    #expect(fixture.model.restorable.isEmpty)
  }

  @Test("should edit a volume without touching its key")
  func editVolume() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a"], to: fixture.model)

    try await fixture.model.editVolume(key: "a", title: "Ashes", objective: "Reach the pass", body: "")

    try await waitUntil { fixture.model.structure.value?.volume("a")?.record.objective == "Reach the pass" }
    #expect(fixture.model.structure.value?.volume("a")?.displayName == "Ashes")
    #expect(fixture.model.structure.value?.volume("a")?.record.body == nil)
  }

  @Test("should create a milestone that starts open and refuse a duplicate")
  func milestones() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    try await fixture.model.createMilestone(key: "crowned", label: "Crowned", subject: nil, kind: .event)
    try await waitUntil { fixture.model.structure.value?.milestone("crowned") != nil }

    #expect(fixture.model.structure.value?.milestone("crowned")?.state == .open)
    #expect(fixture.model.structure.value?.milestone("crowned")?.duplicateClaims.isEmpty == true)
    await #expect(throws: DomainError.self) { try await fixture.model.createMilestone(key: "crowned", label: "Again", subject: nil, kind: .event) }
  }

  @Test("should refuse a milestone about an entity that does not exist")
  func milestoneSubjectRefusal() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    do {
      try await fixture.model.createMilestone(key: "crowned", label: "Crowned", subject: "nobody", kind: .rank)
      Issue.record("expected the unknown subject to be refused")
    } catch {
      #expect(PresentedError(error, known: StoryErrors.headline).detail == "MIL_004")
    }
  }

  @Test("should settle a promise and reopen it")
  func settlePromise() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    try await fixture.model.createPromise(.thread("oath"), label: "The oath is kept")
    try await fixture.model.createPromise(.mystery("who"), label: "Who lit the fire?")
    try await waitUntil { fixture.model.structure.value?.promises.value?.items.count == 2 }
    #expect(fixture.model.structure.value?.promise(.thread("oath"))?.standing == .open)

    await fixture.model.settle(.thread("oath"), .payOff)
    await fixture.model.settle(.mystery("who"), .payOff)
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath"))?.standing == .settled }
    try await waitUntil { fixture.model.structure.value?.promise(.mystery("who"))?.standing == .settled }

    await fixture.model.settle(.thread("oath"), .reopen)
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath"))?.standing == .open }
    #expect(fixture.model.failure == nil)
  }

  @Test("should remove a promise and restore it")
  func removeAndRestorePromise() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createPromise(.thread("oath"), label: "The oath is kept")
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath")) != nil }

    await fixture.model.removePromise(try #require(fixture.model.structure.value?.promise(.thread("oath"))))
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath")) == nil }
    #expect(fixture.model.restorable.count == 1)

    await fixture.model.restore(try #require(fixture.model.restorable.first))
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath")) != nil }
  }

  @Test("should show a localized error when settling a promise that is gone")
  func settleMissingPromise() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    await fixture.model.settle(.thread("ghost"), .payOff)

    #expect(fixture.model.failure?.error.detail == "PMS_001")
    #expect(fixture.model.failure?.error.headline == String(localized: "This promise could not be found. It may have been removed on another device.", table: "Story"))
  }

  @Test("should save a secret with a reveal chapter and an unlock condition")
  func saveSecret() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    try await fixture.model.saveSecret(
      key: "heir", text: "The orphan is the heir", writerNote: "Hint twice", constraintNote: "", revealChapter: 12, unlock: .replace([.chapter(10), .ending]))
    try await waitUntil { fixture.model.structure.value?.secret("heir") != nil }

    let secret = try #require(fixture.model.structure.value?.secret("heir"))
    #expect(secret.revealChapter == 12)
    #expect(secret.writerNote == "Hint twice")
    #expect(UnlockTerm.parse(secret.unlock) == [.chapter(10), .ending])
  }

  @Test("should keep the stored unlock condition when the change says keep")
  func keepUnlock() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.saveSecret(key: "heir", text: "One", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .replace([.ending]))
    try await waitUntil { fixture.model.structure.value?.secret("heir") != nil }

    try await fixture.model.saveSecret(key: "heir", text: "Two", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)

    try await waitUntil { fixture.model.structure.value?.secret("heir")?.text == "Two" }
    #expect(UnlockTerm.parse(fixture.model.structure.value?.secret("heir")?.unlock) == [.ending])
  }

  @Test("should refuse a secret with a blank text")
  func blankSecretRefusal() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }

    do {
      try await fixture.model.saveSecret(key: "heir", text: "", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)
      Issue.record("expected the blank text to be refused")
    } catch {
      #expect(PresentedError(error, known: StoryErrors.headline).headline == String(localized: "A required field is blank.", table: "Story"))
    }
  }

  @Test("should reveal a secret to a character by hand and retract it")
  func manualRevealAndRetraction() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.store.writeDomain { transaction throws(DomainError) in
      try Entities.create(novel: fixture.novel, entity: "mara", type: .character, name: "Mara", in: &transaction)
    }
    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)
    try await waitUntil { fixture.model.characters().map(\.entity) == ["mara"] && fixture.model.structure.value?.secret("heir") != nil }

    try await fixture.model.reveal(secret: "heir", to: "mara", chapter: 4, note: "Overheard")
    try await waitUntil { knowers(fixture.model, of: "heir").count == 1 }

    let entry = try #require(knowers(fixture.model, of: "heir").first)
    #expect(entry.entity == "mara")
    #expect(entry.chapter == 4)
    #expect(entry.source == .manual)
    #expect(fixture.model.entityName("mara") == "Mara")

    await fixture.model.retract(secret: "heir", from: "mara")
    try await waitUntil { knowers(fixture.model, of: "heir").isEmpty }
    #expect(fixture.model.failure == nil)
  }

  @Test("should move a manual reveal to another chapter")
  func revealAgain() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.store.writeDomain { transaction throws(DomainError) in
      try Entities.create(novel: fixture.novel, entity: "mara", type: .character, name: "Mara", in: &transaction)
    }
    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)
    try await fixture.model.reveal(secret: "heir", to: "mara", chapter: 4, note: "")
    try await waitUntil { knowers(fixture.model, of: "heir").first?.chapter == 4 }

    try await fixture.model.reveal(secret: "heir", to: "mara", chapter: 7, note: "")

    try await waitUntil { knowers(fixture.model, of: "heir").first?.chapter == 7 }
    #expect(knowers(fixture.model, of: "heir").count == 1)
  }

  @Test("should refuse to reveal a secret to an unknown character")
  func revealUnknownCharacter() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)

    do {
      try await fixture.model.reveal(secret: "heir", to: "nobody", chapter: 1, note: "")
      Issue.record("expected the unknown character to be refused")
    } catch {
      #expect(PresentedError(error, known: StoryErrors.headline).headline == String(localized: "That character is not in your story bible any more.", table: "Story"))
    }
  }

  @Test("should report a route to a missing secret as not found, and find it again once restored")
  func missingSecretRoute() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    #expect(fixture.model.structure.value?.secret("heir") == nil)
    #expect(fixture.model.structure.value?.secrets.value != nil)

    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep)
    try await waitUntil { fixture.model.structure.value?.secret("heir") != nil }
    await fixture.model.removeSecret(try #require(fixture.model.structure.value?.secret("heir")))
    try await waitUntil { fixture.model.structure.value?.secret("heir") == nil }

    #expect(fixture.model.structure.value?.volume("heir") == nil)
    await fixture.model.restore(try #require(fixture.model.restorable.first))
    try await waitUntil { fixture.model.structure.value?.secret("heir") != nil }
  }

  @Test("should list secrets by key and keep removed ones out")
  func secretOrdering() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    for key in ["b", "a", "c"] { try await fixture.model.saveSecret(key: key, text: key, writerNote: "", constraintNote: "", revealChapter: nil, unlock: .keep) }
    try await waitUntil { fixture.model.structure.value?.secrets.value?.items.count == 3 }

    #expect(fixture.model.structure.value?.secrets.value?.items.map(\.secret) == ["a", "b", "c"])
  }

  @Test("should round-trip unlock terms and reject shapes it cannot edit")
  func unlockTerms() {
    let terms: [UnlockTerm] = [.milestone("crowned"), .volume("a"), .chapter(3), .ending]

    #expect(UnlockTerm.parse(UnlockTerm.condition(terms)) == terms)
    #expect(UnlockTerm.parse(nil) == [])
    #expect(UnlockTerm.condition([]) == nil)
    #expect(UnlockTerm.parse(.object(["any": .array([])])) == nil)
    #expect(UnlockTerm.parse(.object(["all": .array([.object(["moon": .string("full")])])])) == nil)
  }

  @Test("should leave the order alone when the anchor of a relocation is gone")
  func relocateWithMissingAnchor() {
    #expect(VolumeMove.relocate(keys: ["a"], before: "z").applied(to: ["a", "b", "c"]) == ["a", "b", "c"])
    #expect(VolumeMove.relocate(keys: ["a"], before: nil).applied(to: ["a", "b", "c"]) == ["b", "c", "a"])
    #expect(VolumeMove.relocate(keys: ["c"], before: "a").applied(to: ["a", "b", "c"]) == ["c", "a", "b"])
  }

  @Test("should slug a label into a spaceless key")
  func slugs() {
    #expect(StoryKey.slug("Reaches the Capital!") == "reaches-the-capital")
    #expect(StoryKey.isValid("a b") == false)
    #expect(StoryKey.unused(prefix: "volume", taken: ["volume-1", "volume-2"]) == "volume-3")
  }

  @Test("should write only the volumes whose ordinal changes when two volumes swap")
  func swapWritesTwoVolumes() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b", "c"], to: fixture.model)
    let before = try await fixture.store.pendingChanges(limit: Int.max).count

    await fixture.model.moveVolume("a", by: 1)
    try await waitUntil { volumeKeys(fixture.model) == ["b", "a", "c"] }

    #expect(try await fixture.store.pendingChanges(limit: Int.max).count == before + 2)
  }

  @Test("should write nothing when a move leaves the order unchanged")
  func noOpMoveWritesNothing() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b"], to: fixture.model)
    let before = try await fixture.store.pendingChanges(limit: Int.max).count

    await fixture.model.moveVolume("a", by: -1)
    await fixture.model.moveVolumes(from: IndexSet(integer: 0), to: 0)

    #expect(try await fixture.store.pendingChanges(limit: Int.max).count == before)
  }

  @Test("should order from the stored volumes rather than a stale snapshot")
  func moveUsesStoredOrder() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a", "b", "c"], to: fixture.model)

    await fixture.model.moveVolume("c", by: -1)
    await fixture.model.moveVolume("c", by: -1)

    try await waitUntil { volumeKeys(fixture.model) == ["c", "a", "b"] }
  }

  @Test("should flag a milestone claimed by two chapter plans")
  func duplicateClaims() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createMilestone(key: "rise", label: "Rise", subject: nil, kind: .event)
    for chapter in [1, 2] { try await putPlan(chapter, in: fixture, ChapterContract(claimedMilestones: ["rise"])) }

    try await waitUntil { fixture.model.structure.value?.milestone("rise")?.duplicateClaims.isEmpty == false }

    let item = try #require(fixture.model.structure.value?.milestone("rise"))
    #expect(item.state == .planned)
    #expect(item.duplicateClaims.count == 1)
    #expect(item.duplicateNote != nil)
  }

  @Test("should flag a chapter plan that reveals a secret too early")
  func violatedReveal() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.store.writeDomain { transaction throws(DomainError) in
      try Entities.create(novel: fixture.novel, entity: "mara", type: .character, name: "Mara", in: &transaction)
    }
    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: 1, unlock: .keep)
    let learns = [ContractLearn(KnowledgeReveal(entityKey: "mara", factKey: "heir"))]
    try await putPlan(1, in: fixture, ChapterContract(pov: ["mara"], learns: learns))

    try await fixture.model.saveSecret(key: "heir", text: "The orphan is the heir", writerNote: "", constraintNote: "", revealChapter: 9, unlock: .keep)

    try await waitUntil { fixture.model.chapters.value?.reveals.value?[1] == .violated }
  }

  @Test("should count a record this version cannot read instead of listing it")
  func unreadableVolume() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await addVolumes(["a"], to: fixture.model)

    let key = NovelForgeKey.volumeKey(novel: fixture.novel, volume: "bad")
    try await fixture.store.write { transaction in _ = try transaction.set(key.ref, ["natural_key": key.stored]) }

    try await waitUntil { fixture.model.structure.value?.volumes.value?.unreadable == 1 }
    #expect(volumeKeys(fixture.model) == ["a"])
  }

  @Test("should show a faulted part as unavailable with the first fault message")
  func unavailableReason() {
    #expect(StoryUnavailable(faults: []).reason == "")
  }

  @Test("should drop an open promise and offer to reopen it")
  func dropPromise() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createPromise(.thread("oath"), label: "The oath is kept")
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath")) != nil }

    await fixture.model.drop(.thread("oath"))
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath"))?.standing == .dropped }
    await fixture.model.settle(.thread("oath"), .reopen)

    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath"))?.standing == .open }
  }

  @Test("should not name a settled chapter when the novel has no chapters yet")
  func settledWithoutChapters() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createPromise(.thread("oath"), label: "The oath is kept")
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath")) != nil }

    await fixture.model.settle(.thread("oath"), .payOff)
    try await waitUntil { fixture.model.structure.value?.promise(.thread("oath"))?.standing == .settled }

    #expect(fixture.model.structure.value?.promise(.thread("oath"))?.settledChapter == 0)
    #expect(fixture.model.structure.value?.promise(.thread("oath"))?.chapterMark == .opened(1))
  }

  @Test("should show the key once for an untitled volume")
  func untitledVolume() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createVolume(key: "ash", title: "", objective: "", body: "")
    try await waitUntil { fixture.model.structure.value?.volume("ash") != nil }

    #expect(fixture.model.structure.value?.volume("ash")?.hasTitle == false)
    #expect(fixture.model.structure.value?.volume("ash")?.displayName == "ash")
  }

  @Test("should keep the stored milestone kind when the edit does not change it")
  func keepMilestoneKind() async throws {
    let fixture = try await makeFixture()
    defer { fixture.task.cancel() }
    try await fixture.model.createMilestone(key: "crowned", label: "Crowned", subject: nil, kind: .rank)
    try await waitUntil { fixture.model.structure.value?.milestone("crowned") != nil }

    try await fixture.model.editMilestone(key: "crowned", label: "Crowned again", subject: nil, kind: nil)

    try await waitUntil { fixture.model.structure.value?.milestone("crowned")?.record.label == "Crowned again" }
    #expect(fixture.model.structure.value?.milestone("crowned")?.record.kind == .known(.rank))
  }

  private func putPlan(_ chapter: Int, in fixture: Fixture, _ contract: ChapterContract) async throws {
    let novel = fixture.novel
    try await fixture.store.write { transaction in
      _ = try ChapterPlanRecord(novel: novel, chapter: chapter, content: ChapterPlanContent(body: "Plan", contract: contract)).create(in: &transaction)
    }
  }

  private func knowers(_ model: StoryModel, of secret: String) -> [CharacterKnowledgeEntry] {
    model.ledger.value?.knowers(of: secret).value ?? []
  }
}

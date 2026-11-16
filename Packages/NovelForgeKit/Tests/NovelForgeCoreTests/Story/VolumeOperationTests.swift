import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Volumes")
struct VolumeOperationTests {
  @Test
  func shouldCreateAVolumeWithTheReferenceDefaults() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    #expect(live(try await world.volume("one")) == VolumeRecord(novel: novel, volume: "one", ordinal: 0))
  }

  @Test
  func shouldPlaceAVolumeWithoutAnOrdinalAfterTheHighestOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Volumes.create(novel: novel, volume: "a", in: &$0)
      try Volumes.create(novel: novel, volume: "b", ordinal: 7, in: &$0)
      try Volumes.create(novel: novel, volume: "c", in: &$0)
      try Volumes.create(novel: novel, volume: "d", ordinal: Int.max, in: &$0)
      try Volumes.create(novel: novel, volume: "e", in: &$0)
    }
    #expect(try await [world.volume("a"), world.volume("c"), world.volume("e")].map { live($0)?.ordinal } == [0, 8, Int.max])
  }

  @Test
  func shouldRefuseAVolumeForAnUnknownNovel() async throws {
    let world = try await StoryWorld.make(withNovel: false)
    let novel = world.novel
    await world.expect(.novelNotFound(novel)) { try Volumes.create(novel: novel, volume: "one", in: &$0) }
  }

  @Test
  func shouldCountTheTitleInCodePoints() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", title: String(repeating: "\u{1F600}", count: 500), in: &$0) }
  }

  @Test
  func shouldCreateAVolumeWithItsFields() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "two", ordinal: 2, title: "Salt", objective: "Reach the coast", body: "notes", in: &$0) }
    #expect(live(try await world.volume("two")) == VolumeRecord(novel: novel, volume: "two", ordinal: 2, title: "Salt", objective: "Reach the coast", body: "notes"))
  }

  @Test
  func shouldRefuseCreatingAVolumeThatExists() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    await world.expect(.volumeExists("one")) { try Volumes.create(novel: novel, volume: "one", ordinal: 5, in: &$0) }
    #expect(live(try await world.volume("one"))?.ordinal == 0)
  }

  @Test
  func shouldTreatTheSameKeyInOtherNormalisationFormsAsTheSameVolume() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "caf\u{E9}", in: &$0) }
    await world.expect(.volumeExists("caf\u{E9}")) { try Volumes.create(novel: novel, volume: "cafe\u{301}", in: &$0) }
  }

  @Test
  func shouldCreateOverARemovedVolumeAsAFreshOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Volumes.create(novel: novel, volume: "one", ordinal: 4, title: "Old", in: &$0)
      try Volumes.remove(novel: novel, volume: "one", in: &$0)
    }
    try await world.run { try Volumes.create(novel: novel, volume: "one", ordinal: 1, in: &$0) }
    #expect(live(try await world.volume("one")) == VolumeRecord(novel: novel, volume: "one", ordinal: 1))
  }

  @Test
  func shouldRefuseAnEmptyKey() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.invalidKey(field: "volumeKey")) { try Volumes.create(novel: novel, volume: "", in: &$0) }
  }

  @Test
  func shouldHoldTheTitleToFiveHundredCharacters() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", title: String(repeating: "a", count: 500), in: &$0) }
    await world.expect(.tooLong(field: "title", limit: 500)) { try Volumes.create(novel: novel, volume: "two", title: String(repeating: "a", count: 501), in: &$0) }
    let changes = VolumeChanges(title: .set(String(repeating: "\u{1F600}", count: 501)))
    await world.expect(.tooLong(field: "title", limit: 500)) { try Volumes.edit(novel: novel, volume: "one", changes, in: &$0) }
  }

  @Test
  func shouldEditOnlyTheNamedFields() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", ordinal: 3, title: "Tide", objective: "Goal", body: "notes", in: &$0) }
    let changes = VolumeChanges(title: .set("Salt"))
    try await world.run { try Volumes.edit(novel: novel, volume: "one", changes, in: &$0) }
    #expect(live(try await world.volume("one")) == VolumeRecord(novel: novel, volume: "one", ordinal: 3, title: "Salt", objective: "Goal", body: "notes"))
  }

  @Test
  func shouldReorderAndClearFields() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", ordinal: 3, title: "Tide", objective: "Goal", body: "notes", in: &$0) }
    let changes = VolumeChanges(ordinal: .set(1), title: .set(nil), objective: .set(nil), body: .set(nil))
    try await world.run { try Volumes.edit(novel: novel, volume: "one", changes, in: &$0) }
    #expect(live(try await world.volume("one")) == VolumeRecord(novel: novel, volume: "one", ordinal: 1))
  }

  @Test
  func shouldNotWriteWhenNothingChanges() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Volumes.edit(novel: novel, volume: "one", VolumeChanges(), in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldRefuseEditingAVolumeThatIsMissingOrRemoved() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let changes = VolumeChanges(ordinal: .set(2))
    await world.expect(.volumeNotFound("one")) { try Volumes.edit(novel: novel, volume: "one", changes, in: &$0) }
    try await world.run {
      try Volumes.create(novel: novel, volume: "one", in: &$0)
      try Volumes.remove(novel: novel, volume: "one", in: &$0)
    }
    await world.expect(.volumeNotFound("one")) { try Volumes.edit(novel: novel, volume: "one", changes, in: &$0) }
    #expect(isRemoved(try await world.volume("one")))
  }

  @Test
  func shouldRemoveAndRestoreAVolume() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", ordinal: 2, title: "Tide", in: &$0) }
    try await world.run { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    #expect(isRemoved(try await world.volume("one")))
    try await world.run { try Volumes.restore(novel: novel, volume: "one", in: &$0) }
    #expect(live(try await world.volume("one")) == VolumeRecord(novel: novel, volume: "one", ordinal: 2, title: "Tide"))
  }

  @Test
  func shouldRefuseRemovingOrRestoringAMissingVolume() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.volumeNotFound("one")) { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    await world.expect(.volumeNotFound("one")) { try Volumes.restore(novel: novel, volume: "one", in: &$0) }
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    try await world.run { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    await world.expect(.volumeNotFound("one")) { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
  }

  @Test
  func shouldTreatRestoringALiveVolumeAsDone() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Volumes.restore(novel: novel, volume: "one", in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldRefuseRemovingAVolumeAChapterPlanStillNames() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Volumes.create(novel: novel, volume: "one", in: &$0) }
    try await world.seed(try world.plan(chapter: 6, volume: "one"), try world.plan(chapter: 3, volume: "one"), try world.plan(chapter: 1, volume: "two"))
    await world.expect(.volumeInPlan(volume: "one", chapter: 3)) { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    #expect(live(try await world.volume("one")) != nil)
  }

  @Test
  func shouldRemoveAVolumeOnceItsPlansAreGoneOrNameAnotherVolume() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Volumes.create(novel: novel, volume: "one", in: &$0)
      try Volumes.create(novel: novel, volume: "two", in: &$0)
    }
    let plan = try world.plan(chapter: 2, volume: "one")
    try await world.seed(plan, try world.plan(chapter: 1, volume: "two"), try world.plan(chapter: 4))
    _ = try await world.store.write { transaction in try ChapterPlanRecord.remove(plan.ref, in: &transaction) }
    try await world.run { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    #expect(isRemoved(try await world.volume("one")))
  }
}

@Suite("Volume goal met")
struct VolumeGoalMetTests {
  private func volumes(_ world: StoryWorld, _ ordinals: [(String, Int)]) async throws {
    let novel = world.novel
    try await world.run { transaction in
      for (key, ordinal) in ordinals { try Volumes.create(novel: novel, volume: key, ordinal: ordinal, in: &transaction) }
    }
  }

  private func advance(_ world: StoryWorld, _ volume: String) async throws -> VolumeAdvance {
    let novel = world.novel
    return try await world.store.write { try Volumes.markGoalMet(novel: novel, volume: volume, in: &$0) }
  }

  @Test
  func shouldCompleteTheActiveVolumeAndNameTheNextOne() async throws {
    let world = try await StoryWorld.make()
    try await volumes(world, [("two", 2), ("one", 1), ("three", 3)])
    let result = try await advance(world, "one")
    #expect(result == VolumeAdvance(completed: "one", activated: "two"))
    #expect(live(try await world.volume("one"))?.goalMet == true)
    #expect(live(try await world.volume("two"))?.goalMet == false)
  }

  @Test
  func shouldReportNoNextVolumeAfterTheLastOne() async throws {
    let world = try await StoryWorld.make()
    try await volumes(world, [("one", 1)])
    #expect(try await advance(world, "one") == VolumeAdvance(completed: "one", activated: nil))
  }

  @Test
  func shouldRefuseAVolumeThatIsNotActive() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1), ("two", 2)])
    await world.expect(.volumeNotActive("two")) { _ = try Volumes.markGoalMet(novel: novel, volume: "two", in: &$0) }
    #expect(live(try await world.volume("two"))?.goalMet == false)
  }

  @Test
  func shouldRefuseCompletingAVolumeTwice() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1), ("two", 2)])
    _ = try await advance(world, "one")
    await world.expect(.volumeNotActive("one")) { _ = try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) }
  }

  @Test
  func shouldRefuseAMissingOrRemovedVolume() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.volumeNotFound("one")) { _ = try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) }
    try await volumes(world, [("one", 1), ("two", 2)])
    try await world.run { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    await world.expect(.volumeNotFound("one")) { _ = try Volumes.markGoalMet(novel: novel, volume: "one", in: &$0) }
  }

  @Test
  func shouldMakeTheNextVolumeActiveWhenTheActiveOneIsRemoved() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1), ("two", 2)])
    try await world.run { try Volumes.remove(novel: novel, volume: "one", in: &$0) }
    #expect(try await advance(world, "two") == VolumeAdvance(completed: "two", activated: nil))
  }

  @Test
  func shouldBreakAnOrdinalTieByKey() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("b", 1), ("a", 1)])
    await world.expect(.volumeNotActive("b")) { _ = try Volumes.markGoalMet(novel: novel, volume: "b", in: &$0) }
    #expect(try await advance(world, "a") == VolumeAdvance(completed: "a", activated: "b"))
  }

  @Test
  func shouldNeverActivateAVolumeBelowAGoalMetOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1), ("three", 3)])
    _ = try await advance(world, "one")
    try await world.run { try Volumes.create(novel: novel, volume: "two", ordinal: 2, in: &$0) }
    #expect(try await advance(world, "two") == VolumeAdvance(completed: "two", activated: "three"))
  }

  @Test
  func shouldActivateAVolumeInsertedAfterTheLastGoalMetOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1)])
    _ = try await advance(world, "one")
    try await world.run { try Volumes.create(novel: novel, volume: "two", ordinal: 2, in: &$0) }
    #expect(try await advance(world, "two") == VolumeAdvance(completed: "two", activated: nil))
  }

  @Test
  func shouldActivateAVolumeThatIsReorderedToTheFront() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await volumes(world, [("one", 1), ("two", 2)])
    let changes = VolumeChanges(ordinal: .set(0))
    try await world.run { try Volumes.edit(novel: novel, volume: "two", changes, in: &$0) }
    #expect(try await advance(world, "two") == VolumeAdvance(completed: "two", activated: "one"))
  }
}

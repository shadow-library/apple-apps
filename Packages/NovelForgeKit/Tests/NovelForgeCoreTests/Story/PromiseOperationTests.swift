import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Promises")
struct PromiseOperationTests {
  @Test
  func shouldCreateAThreadAndAMysteryAtTheNextWritableChapter() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(try world.final(chapter: 1), try world.draft(chapter: 2))
    try await world.run {
      try Promises.create(novel: novel, .thread("debt"), label: "Mara owes a debt", in: &$0)
      try Promises.create(novel: novel, .mystery("who"), label: "Who lit the fire?", in: &$0)
    }
    #expect(live(try await world.thread("debt")) == ThreadRecord(novel: novel, thread: "debt", summary: "Mara owes a debt", openedChapter: 3))
    #expect(live(try await world.mystery("who")) == MysteryRecord(novel: novel, mystery: "who", question: "Who lit the fire?", openedChapter: 3))
  }

  @Test
  func shouldStartAtChapterOneOnAnEmptyNovelAndKeepAnExplicitChapter() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0)
      try Promises.create(novel: novel, .thread("b"), label: "B", openedChapter: 9, in: &$0)
    }
    #expect(live(try await world.thread("a"))?.openedChapter == 1)
    #expect(live(try await world.thread("b"))?.openedChapter == 9)
  }

  @Test
  func shouldSkipChaptersThatAreStartedOrFinalButNotRemovedDrafts() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let removed = try world.draft(chapter: 1)
    try await world.seed(removed, try world.final(chapter: 2), try world.draft(chapter: 3))
    _ = try await world.store.write { transaction in try DraftRecord.remove(removed.ref, in: &transaction) }
    try await world.run { try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0) }
    #expect(live(try await world.thread("a"))?.openedChapter == 1)
  }

  @Test
  func shouldRefuseAPromiseForAnUnknownNovel() async throws {
    let world = try await StoryWorld.make(withNovel: false)
    let novel = world.novel
    await world.expect(.novelNotFound(novel)) { try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0) }
  }

  @Test
  func shouldKeepThreadsAndMysteriesInSeparateKeySpaces() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("same"), label: "T", in: &$0)
      try Promises.create(novel: novel, .mystery("same"), label: "M", in: &$0)
    }
    await world.expect(.promiseExists(.thread("same"))) { try Promises.create(novel: novel, .thread("same"), label: "T2", in: &$0) }
    await world.expect(.promiseExists(.mystery("same"))) { try Promises.create(novel: novel, .mystery("same"), label: "M2", in: &$0) }
  }

  @Test
  func shouldRefuseABlankLabelAndAKeyWithSpaces() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.blank(field: "label")) { try Promises.create(novel: novel, .thread("a"), label: " ", in: &$0) }
    await world.expect(.invalidKey(field: "key")) { try Promises.create(novel: novel, .mystery("a b"), label: "A", in: &$0) }
    await world.expect(.invalidKey(field: "key")) { try Promises.create(novel: novel, .thread(""), label: "A", in: &$0) }
  }

  @Test
  func shouldCreateOverARemovedPromiseAsAFreshOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "Old", openedChapter: 4, in: &$0)
      try Promises.drop(novel: novel, .thread("a"), in: &$0)
      try Promises.remove(novel: novel, .thread("a"), in: &$0)
    }
    try await world.run { try Promises.create(novel: novel, .thread("a"), label: "New", openedChapter: 2, in: &$0) }
    #expect(live(try await world.thread("a")) == ThreadRecord(novel: novel, thread: "a", summary: "New", openedChapter: 2))
  }

  @Test
  func shouldPayOffAThreadAtTheLatestChapterAndReopenIt() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(try world.final(chapter: 1), try world.draft(chapter: 2), try world.draft(chapter: 5))
    try await world.run { try Promises.create(novel: novel, .thread("debt"), label: "Debt", in: &$0) }
    try await world.run { try Promises.update(novel: novel, .thread("debt"), settlement: .payOff, in: &$0) }
    #expect(live(try await world.thread("debt"))?.status == ThreadProgress(state: .known(.closed), chapter: 5))
    try await world.run { try Promises.update(novel: novel, .thread("debt"), settlement: .reopen, in: &$0) }
    #expect(live(try await world.thread("debt"))?.status == ThreadProgress(state: .known(.open), chapter: nil))
  }

  @Test
  func shouldResolveAMysteryAtChapterZeroWhenNothingIsWrittenYet() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Promises.create(novel: novel, .mystery("who"), label: "Who?", in: &$0) }
    try await world.run { try Promises.update(novel: novel, .mystery("who"), settlement: .payOff, in: &$0) }
    #expect(live(try await world.mystery("who"))?.status == MysteryProgress(state: .known(.resolved), chapter: 0))
  }

  @Test
  func shouldRewordAPromiseAndKeepTheLabelWhenTheNewOneIsBlank() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("debt"), label: "Debt", in: &$0)
      try Promises.create(novel: novel, .mystery("who"), label: "Who?", in: &$0)
    }
    try await world.run {
      try Promises.update(novel: novel, .thread("debt"), label: "  Mara's debt ", in: &$0)
      try Promises.update(novel: novel, .mystery("who"), label: "Who lit it?", in: &$0)
    }
    #expect(live(try await world.thread("debt"))?.summary == "Mara's debt")
    #expect(live(try await world.mystery("who"))?.question == "Who lit it?")
    try await world.run {
      try Promises.update(novel: novel, .thread("debt"), label: "   ", in: &$0)
      try Promises.update(novel: novel, .mystery("who"), label: "", in: &$0)
    }
    #expect(live(try await world.thread("debt"))?.summary == "Mara's debt")
    #expect(live(try await world.mystery("who"))?.question == "Who lit it?")
  }

  @Test
  func shouldFallBackToTheKeyForAThreadWithoutASummary() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(ThreadRecord(novel: novel, thread: "bare"))
    try await world.run { try Promises.update(novel: novel, .thread("bare"), label: " ", in: &$0) }
    #expect(live(try await world.thread("bare"))?.summary == "bare")
  }

  @Test
  func shouldNotWriteAnEmptyUpdate() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Promises.update(novel: novel, .thread("a"), in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldRefuseAnOperationOnAMissingOrRemovedPromise() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let missing = PromiseRef.mystery("who")
    await world.expect(.promiseNotFound(missing)) { try Promises.update(novel: novel, missing, label: "x", in: &$0) }
    await world.expect(.promiseNotFound(missing)) { try Promises.setPayoff(novel: novel, missing, .someday(), in: &$0) }
    await world.expect(.promiseNotFound(missing)) { try Promises.drop(novel: novel, missing, in: &$0) }
    await world.expect(.promiseNotFound(missing)) { try Promises.remove(novel: novel, missing, in: &$0) }
    await world.expect(.promiseNotFound(missing)) { try Promises.restore(novel: novel, missing, in: &$0) }
    try await world.run {
      try Promises.create(novel: novel, missing, label: "Who?", in: &$0)
      try Promises.remove(novel: novel, missing, in: &$0)
    }
    await world.expect(.promiseNotFound(missing)) { try Promises.drop(novel: novel, missing, in: &$0) }
  }

  @Test
  func shouldDropAPromiseButKeepItsRecordAndChapter() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(try world.draft(chapter: 3))
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0)
      try Promises.update(novel: novel, .thread("a"), settlement: .payOff, in: &$0)
      try Promises.create(novel: novel, .mystery("m"), label: "M", in: &$0)
    }
    try await world.run {
      try Promises.drop(novel: novel, .thread("a"), in: &$0)
      try Promises.drop(novel: novel, .mystery("m"), in: &$0)
    }
    #expect(live(try await world.thread("a"))?.status == ThreadProgress(state: .known(.dropped), chapter: 3))
    #expect(live(try await world.mystery("m"))?.status == MysteryProgress(state: .known(.dropped), chapter: nil))
  }

  @Test
  func shouldSetAPayoffTargetAndKeepTheOmittedParts() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0)
      try Promises.create(novel: novel, .mystery("m"), label: "M", in: &$0)
    }
    try await world.run {
      try Promises.setPayoff(novel: novel, .thread("a"), .target(milestone: .set("ascends"), window: .set(12)), in: &$0)
      try Promises.setPayoff(novel: novel, .mystery("m"), .target(volume: .set("two"), dormant: true), in: &$0)
    }
    try await world.run { try Promises.setPayoff(novel: novel, .thread("a"), .target(volume: .set("one")), in: &$0) }
    let thread = live(try await world.thread("a"))
    #expect(thread?.payoffMilestone == "ascends")
    #expect(thread?.payoffVolume == "one")
    #expect(thread?.payoffWindow == 12)
    #expect(thread?.dormant == false)
    let mystery = live(try await world.mystery("m"))
    #expect(mystery?.payoffVolume == "two")
    #expect(mystery?.dormant == true)
  }

  @Test
  func shouldClearEveryTargetForSomedayAndOnlyChangeDormancyWhenGiven() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "A", in: &$0)
      try Promises.setPayoff(novel: novel, .thread("a"), .target(milestone: .set("m"), volume: .set("v"), window: .set(4), dormant: true), in: &$0)
    }
    try await world.run { try Promises.setPayoff(novel: novel, .thread("a"), .someday(), in: &$0) }
    var thread = live(try await world.thread("a"))
    #expect(thread?.payoffMilestone == nil && thread?.payoffVolume == nil && thread?.payoffWindow == nil)
    #expect(thread?.dormant == true)
    try await world.run { try Promises.setPayoff(novel: novel, .thread("a"), .someday(dormant: false), in: &$0) }
    thread = live(try await world.thread("a"))
    #expect(thread?.dormant == false)
  }

  @Test
  func shouldClearASingleTarget() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .mystery("m"), label: "M", in: &$0)
      try Promises.setPayoff(novel: novel, .mystery("m"), .target(milestone: .set("m"), window: .set(4)), in: &$0)
      try Promises.setPayoff(novel: novel, .mystery("m"), .target(window: .set(nil)), in: &$0)
    }
    let mystery = live(try await world.mystery("m"))
    #expect(mystery?.payoffMilestone == "m")
    #expect(mystery?.payoffWindow == nil)
  }

  @Test
  func shouldRemoveAndRestoreAPromise() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Promises.create(novel: novel, .thread("a"), label: "A", openedChapter: 2, in: &$0)
      try Promises.create(novel: novel, .mystery("m"), label: "M", openedChapter: 3, in: &$0)
      try Promises.remove(novel: novel, .thread("a"), in: &$0)
      try Promises.remove(novel: novel, .mystery("m"), in: &$0)
    }
    #expect(isRemoved(try await world.thread("a")))
    #expect(isRemoved(try await world.mystery("m")))
    try await world.run {
      try Promises.restore(novel: novel, .thread("a"), in: &$0)
      try Promises.restore(novel: novel, .mystery("m"), in: &$0)
      try Promises.restore(novel: novel, .mystery("m"), in: &$0)
    }
    #expect(live(try await world.thread("a"))?.openedChapter == 2)
    #expect(live(try await world.mystery("m"))?.openedChapter == 3)
  }
}

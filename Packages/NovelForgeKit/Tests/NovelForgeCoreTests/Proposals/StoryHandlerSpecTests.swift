import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

extension StoryWorld {
  /// Applies `op`, then runs its inverse: the whole-card revert of a one-op card.
  func applyThenRevert(_ json: String, between check: () async throws -> Void) async throws {
    let op = try storyOp(json)
    let step = try await apply(op).get()
    try await check()
    _ = try await undo(op, try #require(step.inverse)).get()
  }

  func refuses(_ json: String, with expected: ApplyError, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let before = try await writeCount()
    let outcome = try await apply(json)
    #expect(throws: expected, sourceLocation: sourceLocation) { try outcome.get() }
    #expect(try await writeCount() == before, "a refused op wrote", sourceLocation: sourceLocation)
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-promises.spec.ts
@Suite("Story handlers: promises (proposal-apply-promises.spec.ts)")
struct StoryHandlerPromiseSpecTests {
  // :73
  @Test func shouldCreateAThreadPromiseAndRemoveItOnRevert() async throws {
    let world = try await StoryWorld.make()
    try await world.applyThenRevert(#"{"op":"promise.create","kind":"thread","key":"the-ledger","label":"Who has the ledger.","openedChapter":3}"#) {
      let current = try await world.thread("the-ledger")
      #expect(live(current) == ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger.", openedChapter: 3))
    }
    #expect(isRemoved(try await world.thread("the-ledger")))
  }

  // :83
  @Test func shouldRefuseCreatingAPromiseWhoseKeyAlreadyExists() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Existing."))
    try await world.refuses(#"{"op":"promise.create","kind":"thread","key":"the-ledger","label":"Who has the ledger."}"#, with: .domain(.promiseExists(.thread("the-ledger"))))
  }

  // :91
  @Test func shouldUpdateAPromiseLabelAndRevertItToTheOriginal() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(MysteryRecord(novel: world.novel, mystery: "who-took-it", question: "Who took the ledger?"))
    try await world.applyThenRevert(#"{"op":"promise.update","kind":"mystery","key":"who-took-it","label":"Who really took the ledger?"}"#) {
      let current = try await world.mystery("who-took-it")
      #expect(live(current)?.question == "Who really took the ledger?")
    }
    #expect(live(try await world.mystery("who-took-it"))?.question == "Who took the ledger?")
  }

  // :103
  @Test func shouldClosePaidOffStampingTheLatestChapterAndRevertToOpenWithNoChapter() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger."), try world.final(chapter: 5))
    try await world.applyThenRevert(#"{"op":"promise.update","kind":"thread","key":"the-ledger","status":"paid_off"}"#) {
      let current = try await world.thread("the-ledger")
      #expect(live(current)?.status == ThreadProgress(state: .known(.closed), chapter: 5))
    }
    #expect(live(try await world.thread("the-ledger"))?.status == ThreadProgress(state: .known(.open), chapter: nil))
  }

  // :116
  @Test func shouldRefuseALastAdvancedChapterAheadOfTheLatestChapter() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger."), try world.final(chapter: 3))
    try await world.refuses(
      #"{"op":"promise.update","kind":"thread","key":"the-ledger","lastAdvancedChapter":9}"#,
      with: ApplyError.refused(.lastAdvancedAhead(chapter: 9, latest: 3)))
    #expect(StoryPromises.lastAdvancedRefusal(9, latest: 3) == .lastAdvancedAhead(chapter: 9, latest: 3))
    #expect(ApplyRefusal.lastAdvancedAhead(chapter: 9, latest: 3).code == "PMS_003")
  }

  // :125. Deviation: the chapter a promise last advanced in has no native field, so a lastAdvancedChapter the reference would store is refused instead; the
  // exact null-label revert is shown through a status change
  @Test func shouldRefuseALastAdvancedChapterItCannotStoreAndRevertANullLabelExactly() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: nil), try world.final(chapter: 5))
    try await world.refuses(
      #"{"op":"promise.update","kind":"thread","key":"the-ledger","lastAdvancedChapter":2}"#, with: ApplyError.refused(.lastAdvancedUntracked))
    #expect(StoryPromises.lastAdvancedRefusal(2, latest: 5) == .lastAdvancedUntracked)
    #expect(StoryPromises.lastAdvancedRefusal(5, latest: 5) == .lastAdvancedUntracked)
    try await world.applyThenRevert(#"{"op":"promise.update","kind":"thread","key":"the-ledger","status":"paid_off"}"#) {
      let current = try await world.thread("the-ledger")
      #expect(live(current)?.summary == nil)
    }
    #expect(live(try await world.thread("the-ledger")) == ThreadRecord(novel: world.novel, thread: "the-ledger", summary: nil))
  }

  // :138, :225
  @Test func shouldRefuseUpdatingOrDroppingAPromiseThatDoesNotExist() async throws {
    let world = try await StoryWorld.make()
    try await world.refuses(#"{"op":"promise.update","kind":"thread","key":"missing","label":"x"}"#, with: .domain(.promiseNotFound(.thread("missing"))))
    try await world.refuses(#"{"op":"promise.drop","kind":"thread","key":"missing"}"#, with: .domain(.promiseNotFound(.thread("missing"))))
    try await world.refuses(#"{"op":"promise.set_payoff","kind":"mystery","key":"missing","someday":true}"#, with: .domain(.promiseNotFound(.mystery("missing"))))
  }

  // :143
  @Test func shouldSetAPayoffTargetAndDormancyAndRevertToSomedayAndNotDormant() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger."))
    try await world.applyThenRevert(#"{"op":"promise.set_payoff","kind":"thread","key":"the-ledger","payoffMilestoneKey":"reveal-1","dormant":true}"#) {
      let thread = live(try await world.thread("the-ledger"))
      #expect(thread?.payoffMilestone == "reveal-1" && thread?.dormant == true)
    }
    let thread = live(try await world.thread("the-ledger"))
    #expect(thread?.payoffMilestone == nil && thread?.dormant == false)
  }

  // :157
  @Test func shouldClearAPayoffTargetWithSomedayAndRevertRestoresTheOriginalValues() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger.", payoffMilestone: "reveal-1"))
    try await world.applyThenRevert(#"{"op":"promise.set_payoff","kind":"thread","key":"the-ledger","someday":true}"#) {
      let thread = live(try await world.thread("the-ledger"))
      #expect(thread?.payoffMilestone == nil && thread?.payoffVolume == nil && thread?.payoffWindow == nil)
    }
    let thread = live(try await world.thread("the-ledger"))
    #expect(thread?.payoffMilestone == "reveal-1" && thread?.payoffVolume == nil && thread?.payoffWindow == nil)
  }

  // :179
  @Test func shouldMoveAPayoffFromAVolumeToAChapterWindowAndRevertRestoresTheVolume() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger.", payoffVolume: "vol_1"))
    try await world.applyThenRevert(#"{"op":"promise.set_payoff","kind":"thread","key":"the-ledger","payoffWindow":12,"payoffVolumeKey":null}"#) {
      let thread = live(try await world.thread("the-ledger"))
      #expect(thread?.payoffVolume == nil && thread?.payoffWindow == 12)
    }
    let thread = live(try await world.thread("the-ledger"))
    #expect(thread?.payoffVolume == "vol_1" && thread?.payoffWindow == nil)
  }

  // :201
  @Test func shouldDropAResolvedMysteryAndRevertRestoresResolvedRatherThanOpen() async throws {
    let world = try await StoryWorld.make()
    let resolved = MysteryProgress(state: .known(.resolved), chapter: 4)
    try await world.seed(MysteryRecord(novel: world.novel, mystery: "who-took-it", question: "Who took the ledger?", status: resolved))
    try await world.applyThenRevert(#"{"op":"promise.drop","kind":"mystery","key":"who-took-it"}"#) {
      let current = try await world.mystery("who-took-it")
      #expect(live(current)?.status == MysteryProgress(state: .known(.dropped), chapter: 4))
    }
    #expect(live(try await world.mystery("who-took-it"))?.status == resolved)
  }

  // promise.handler.ts:171: someday clears the targets and takes the dormancy the op gives
  @Test func shouldKeepTheDormancyASomedayPayoffSets() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger.", payoffWindow: 4))
    _ = try await world.apply(#"{"op":"promise.set_payoff","kind":"thread","key":"the-ledger","someday":true,"dormant":true}"#).get()
    let thread = live(try await world.thread("the-ledger"))
    #expect(thread?.dormant == true && thread?.payoffWindow == nil)
  }

  // :213
  @Test func shouldDropAPromiseWithoutRemovingItAndRevertRestoresItsPriorStatus() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(MysteryRecord(novel: world.novel, mystery: "who-took-it", question: "Who took the ledger?"))
    try await world.applyThenRevert(#"{"op":"promise.drop","kind":"mystery","key":"who-took-it"}"#) {
      let current = try await world.mystery("who-took-it")
      #expect(live(current)?.status.state == .known(.dropped))
    }
    #expect(live(try await world.mystery("who-took-it"))?.status.state == .known(.open))
  }

  @Test func shouldOpenANewPromiseAtTheNextWritableChapterWhenTheOpDoesNotSay() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(try world.final(chapter: 1), try world.final(chapter: 2))
    _ = try await world.apply(#"{"op":"promise.create","kind":"mystery","key":"door","label":"Who opened it?"}"#).get()
    #expect(live(try await world.mystery("door"))?.openedChapter == 3)
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-story-fields.spec.ts, proposal-apply-tx.spec.ts:55
@Suite("Story handlers: the premise (proposal-apply-story-fields.spec.ts)")
struct StoryHandlerPremiseSpecTests {
  // story-fields.spec.ts:33
  @Test func shouldWriteEachStoryFieldTheOpNamesTrimmedAndLeaveTheRestAlone() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { transaction in
      var edit = NovelEdit()
      edit.premise = .set("Two strangers wake up after the Ascend.")
      edit.ending = .set("They hold.")
      _ = try NovelRecord.edit(id: novel, edit, in: &transaction)
    }
    _ = try await world.apply(#"{"op":"premise.update","opposition":"  Hunger, cold and the climbing Ravening.  ","readerPromise":"They hold the campus."}"#).get()
    let record = try #require(try await world.novelRecord())
    #expect(record.opposition == "Hunger, cold and the climbing Ravening." && record.readerPromise == "They hold the campus.")
    #expect(record.premise == "Two strangers wake up after the Ascend." && record.ending == "They hold.")
  }

  // proposal-apply-tx.spec.ts:55; premise.handler.ts:30: the instructions become the novel's additions to the default writing instructions
  @Test func shouldWriteThePremiseAsGivenAndTheInstructionsAsTheWritingStyle() async throws {
    let world = try await StoryWorld.make()
    _ = try await world.apply(#"{"op":"premise.update","premise":" A ferryman carries the dead. ","instructions":"  Keep it terse.\n\n","theme":"   "}"#).get()
    let record = try #require(try await world.novelRecord())
    #expect(record.premise == " A ferryman carries the dead. ")
    #expect(record.writingStyle == writingInstructionAdditions("  Keep it terse.\n\n") && record.writingStyle == "Keep it terse.")
    #expect(record.theme == nil)
  }

  @Test func shouldWriteNothingForAnUpdateThatNamesNoField() async throws {
    let world = try await StoryWorld.make()
    let before = try await world.writeCount()
    let step = try await world.apply(#"{"op":"premise.update"}"#).get()
    #expect(step.inverse == (try storyInverse(#"{"op":"premise.update"}"#)))
    #expect(try await world.writeCount() == before)
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-fact-reveal.spec.ts, proposal-apply-tx.spec.ts:106
@Suite("Story handlers: facts (proposal-apply-fact-reveal.spec.ts)")
struct StoryHandlerFactSpecTests {
  private func dated(_ world: StoryWorld, revealChapter: Int?) -> SecretRecord {
    SecretRecord(novel: world.novel, secret: "f1", text: "the vault is empty", revealChapter: revealChapter)
  }

  // fact-reveal.spec.ts:33
  @Test func shouldKeepTheExistingRevealDateWhenTheOpOmitsIt() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(dated(world, revealChapter: 12))
    _ = try await world.apply(#"{"op":"fact.upsert","factKey":"f1","body":"edited"}"#).get()
    #expect(live(try await world.secret("f1"))?.revealChapter == 12)
    #expect(live(try await world.secret("f1"))?.text == "edited")
  }

  // fact-reveal.spec.ts:42, :53
  @Test func shouldDateAnUndatedFactAndCaptureAnExplicitNullToRestore() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(dated(world, revealChapter: nil))
    let step = try await world.apply(#"{"op":"fact.upsert","factKey":"f1","revealChapter":30}"#).get()
    #expect(live(try await world.secret("f1"))?.revealChapter == 30)
    #expect(step.inverse?["revealChapter"] == .null)
  }

  // tx.spec.ts:107
  @Test func shouldClearARevealDateAndCaptureAnInverseThatRestoresIt() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(dated(world, revealChapter: 12))
    let step = try await world.apply(#"{"op":"fact.upsert","factKey":"f1","revealChapter":null}"#).get()
    #expect(live(try await world.secret("f1"))?.revealChapter == nil)
    #expect(step.inverse?["revealChapter"] == .int(12))
  }

  // fact.handler.ts:35
  @Test func shouldRefuseANewFactWithoutABody() async throws {
    let world = try await StoryWorld.make()
    try await world.refuses(#"{"op":"fact.upsert","factKey":"f1","revealChapter":3}"#, with: ApplyError.refused(.notAllowed))
    try await world.seed(dated(world, revealChapter: 12))
    _ = try await world.store.write { transaction in try SecretRecord.remove(novel: SchemaFixture.novel, secret: "f1", in: &transaction) }
    try await world.refuses(#"{"op":"fact.upsert","factKey":"f1","revealChapter":3}"#, with: ApplyError.refused(.notAllowed))
  }

  // fact.handler.ts:41-48: a blank writer note clears it, clues are normalised, and changed clues may not name a give-away term
  @Test func shouldMergeTheFactAsTheServiceDoesAndRefuseAClueNamingAGiveaway() async throws {
    let world = try await StoryWorld.make()
    _ = try await world.apply(#"{"op":"fact.upsert","factKey":"f1","body":"Mara is the heir.","writerNote":"   ","terms":["heir"],"allowedClues":[" ring ","ring","seal"]}"#).get()
    let fact = try #require(live(try await world.secret("f1")))
    #expect(fact.writerNote == nil && fact.cluesAndTerms == CluesAndTerms(clues: ["ring", "seal"], terms: ["heir"]))
    try await world.refuses(#"{"op":"fact.upsert","factKey":"f1","allowedClues":["the heir's ring"]}"#, with: .domain(.clueNamesTerm(#""the heir's ring" names "heir""#)))
    try await world.refuses(
      #"{"op":"fact.upsert","factKey":"f2","body":"B.","terms":["crown"],"allowedClues":["a crown"]}"#, with: .domain(.clueNamesTerm(#""a crown" names "crown""#)))
    #expect(DomainError.clueNamesTerm("r").code == "FCT_006")
  }

  // proposal-revert.service.ts:148 runs the inverse through applyFactUpsert, so restored clues that name a term are refused as an apply's would be
  @Test func shouldRefuseAnUndoWhoseRestoredCluesNameATerm() async throws {
    let world = try await StoryWorld.make()
    let named = SecretRecord(novel: world.novel, secret: "f1", text: "Mara is the heir.", cluesAndTerms: CluesAndTerms(clues: ["the heir's ring"], terms: ["heir"]))
    try await world.seed(named)
    let op = try storyOp(#"{"op":"fact.upsert","factKey":"f1","allowedClues":["a seal"]}"#)
    let step = try await world.apply(op).get()
    let before = try await world.writeCount()
    let outcome = try await world.undo(op, try #require(step.inverse))
    #expect(throws: ApplyError.domain(.clueNamesTerm(#""the heir's ring" names "heir""#))) { try outcome.get() }
    #expect(try await world.writeCount() == before)
  }

  // fact.handler.ts:47: the undo of a removal finds no row, so every clue it brings back is judged
  @Test func shouldRefuseUndoingARemovalWhoseCluesNameATerm() async throws {
    let world = try await StoryWorld.make()
    let named = SecretRecord(novel: world.novel, secret: "f1", text: "Mara is the heir.", cluesAndTerms: CluesAndTerms(clues: ["the heir's ring"], terms: ["heir"]))
    try await world.seed(named)
    let op = try storyOp(#"{"op":"fact.remove","factKey":"f1"}"#)
    let step = try await world.apply(op).get()
    let before = try await world.writeCount()
    let outcome = try await world.undo(op, try #require(step.inverse))
    #expect(throws: ApplyError.domain(.clueNamesTerm(#""the heir's ring" names "heir""#))) { try outcome.get() }
    #expect(try await world.writeCount() == before)
    #expect(isRemoved(try await world.secret("f1")))
  }

  // fact.handler.ts:64
  @Test func shouldRefuseRemovingAFactThatDoesNotExist() async throws {
    let world = try await StoryWorld.make()
    try await world.refuses(#"{"op":"fact.remove","factKey":"f1"}"#, with: .domain(.secretNotFound("f1")))
  }

  // fact.handler.ts:66 (FCT_003) is not ported: a removal cascades nothing here, so the manual reveal stands and comes back with its fact
  @Test func shouldRemoveAFactWithAManualRevealAndBringBothBackOnRevert() async throws {
    let world = try await StoryWorld.make()
    let mara = world.entity("mara")
    let reveal = CharacterKnowledgeRecord(novel: world.novel, fact: "f1", entity: "mara", reveal: ManualReveal(chapter: 2, note: nil))
    try await world.seed(mara, dated(world, revealChapter: 12), reveal)
    try await world.applyThenRevert(#"{"op":"fact.remove","factKey":"f1"}"#) {
      let current = try await world.secret("f1")
      #expect(isRemoved(current))
    }
    #expect(live(try await world.secret("f1")) == dated(world, revealChapter: 12))
    #expect(live(try await world.knowledge(fact: "f1", entity: "mara")) == reveal)
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-volumes.spec.ts, proposal-apply-tx.spec.ts:66-93
@Suite("Story handlers: volumes (proposal-apply-volumes.spec.ts)")
struct StoryHandlerVolumeSpecTests {
  private func states(_ world: StoryWorld) async throws -> [String: VolumeState] {
    let novel = world.novel
    let volumes = try await world.read { try VolumeRecord.listing(novel: novel, in: $0).live }
    return Dictionary(uniqueKeysWithValues: volumeStandings(of: volumes).map { ($0.volume, $0.state) })
  }

  // tx.spec.ts:66
  @Test func shouldRefuseToRemoveAVolumeAChapterPlanStillBelongsTo() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_4", ordinal: 4), try world.plan(chapter: 3, volume: "volume_4"))
    try await world.refuses(#"{"op":"volume.remove","volumeKey":"volume_4"}"#, with: .domain(.volumeInPlan(volume: "volume_4", chapter: 3)))
    try await world.refuses(#"{"op":"volume.remove","volumeKey":"volume_9"}"#, with: .domain(.volumeNotFound("volume_9")))
  }

  // tx.spec.ts:85
  @Test func shouldWriteOnlyTheGoalFieldsTheOpNames() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_4", ordinal: 4, title: "The Flood", objective: "Reach the far bank.", goalMet: true))
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_4","objective":"Burn the ferry.","state":"not_started"}"#).get()
    #expect(
      live(try await world.volume("volume_4"))
        == VolumeRecord(novel: world.novel, volume: "volume_4", ordinal: 4, title: "The Flood", objective: "Burn the ferry.", goalMet: true))
  }

  // volume.handler.ts:24: a new volume without an ordinal is placed at 0
  // volume.handler.ts:24 stores a new volume without an ordinal at 0 and leaves the active one in place; here the order decides activation, so the volume goes
  // after the others and the active volume stays as the reference leaves it
  @Test func shouldPlaceANewVolumeWithoutAnOrdinalAfterTheOthersAndKeepTheActiveOne() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v1", ordinal: 1, title: "One"), VolumeRecord(novel: world.novel, volume: "v2", ordinal: 3))
    let step = try await world.apply(#"{"op":"volume.upsert","volumeKey":"interlude","title":"Interlude"}"#).get()
    #expect(try await states(world) == ["v1": .active, "v2": .notStarted, "interlude": .notStarted])
    #expect(live(try await world.volume("interlude"))?.ordinal == 4)
    #expect(step.planEdits == [.volume("interlude", ordinal: 4)])
  }

  @Test func shouldRefuseANewVolumeWithoutAnOrdinalWhileAVolumeCannotBeRead() async throws {
    let world = try await StoryWorld.make()
    let broken = try NovelForgeKey(novel: world.novel, .volume("broken"))
    try await world.run { _ = try $0.set(broken.ref, ["natural_key": broken.stored, "removed": .bool(false)]) }
    let refusal = ApplyRefusal.unreadableReferences(kind: NovelForgeKind.volume.rawValue, count: 1)
    try await world.refuses(#"{"op":"volume.upsert","volumeKey":"v9","title":"T"}"#, with: ApplyError.refused(refusal))
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"v9","ordinal":2,"title":"T"}"#).get()
  }

  @Test func shouldReturnTheOrdinalAVolumeKeepsWhenAnEditLeavesItOut() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_4", ordinal: 4))
    let step = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_4","title":"The Flood"}"#).get()
    #expect(step.planEdits == [.volume("volume_4", ordinal: 4)])
  }

  // N1: a removed volume comes back in one write of the captured content, which no title limit can refuse halfway
  @Test func shouldRestoreARemovedVolumeInOneWrite() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v1", ordinal: 1, title: "One", goalMet: true))
    let op = try storyOp(#"{"op":"volume.remove","volumeKey":"v1"}"#)
    _ = try await world.apply(op).get()
    let long = String(repeating: "x", count: 600)
    let before = try await world.writeCount()
    let inverse = try storyInverse(#"{"op":"volume.upsert","volumeKey":"v1","ordinal":2,"title":"\#(long)","objective":null,"body":null}"#)
    _ = try await world.undo(op, inverse).get()
    #expect(try await world.writeCount() == before + 1)
    #expect(live(try await world.volume("v1")) == VolumeRecord(novel: world.novel, volume: "v1", ordinal: 2, title: long, goalMet: true))
  }

  // volumes.spec.ts:169
  @Test func shouldActivateANovelsFirstVolumeOnInsert() async throws {
    let world = try await StoryWorld.make()
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_1","ordinal":1,"title":"The Crossing"}"#).get()
    #expect(try await states(world) == ["volume_1": .active])
  }

  // volumes.spec.ts:177
  @Test func shouldLeaveASecondInsertNotStartedWhileAVolumeIsActive() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_1", ordinal: 1, title: "The Crossing"))
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_2","ordinal":2,"title":"The Far Shore"}"#).get()
    #expect(try await states(world) == ["volume_1": .active, "volume_2": .notStarted])
  }

  // volumes.spec.ts:190
  @Test func shouldActivateTheNewVolumeOnceEveryEarlierOneIsGoalMet() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_1", ordinal: 1, goalMet: true))
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_2","ordinal":2,"title":"The Far Shore"}"#).get()
    #expect(try await states(world)["volume_2"] == .active)
  }

  // volumes.spec.ts:200
  @Test func shouldNotActivateAnInsertBelowAGoalMetVolumesOrdinal() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_2", ordinal: 2, goalMet: true))
    _ = try await world.apply(#"{"op":"volume.upsert","volumeKey":"volume_1","ordinal":1,"title":"Backfilled prologue"}"#).get()
    #expect(try await states(world)["volume_1"] == .notStarted)
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-plan-rules.spec.ts:109-163
@Suite("Story handlers: milestones (proposal-apply-plan-rules.spec.ts)")
struct StoryHandlerMilestoneSpecTests {
  private func rankFour(_ world: StoryWorld, subject: String? = nil) -> MilestoneRecord {
    MilestoneRecord(novel: world.novel, milestone: "lamp_rank_4", label: "Mira reaches the fourth rank", subject: subject, kind: .known(.rank))
  }

  // :110
  @Test func shouldRefuseASubjectThatIsNotAnEntityOfTheNovel() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(rankFour(world))
    try await world.refuses(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","subjectEntityKey":"nobody"}"#, with: .domain(.milestoneSubjectUnknown("nobody")))
  }

  // milestone.handler.ts:40: a subject the milestone already names is not checked again
  @Test func shouldKeepASubjectItAlreadyNamesEvenOnceItsEntityIsGone() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(rankFour(world, subject: "mira"))
    _ = try await world.apply(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","subjectEntityKey":" mira "}"#).get()
    #expect(live(try await world.milestone("lamp_rank_4")) == rankFour(world, subject: "mira"))
  }

  // :117
  @Test func shouldRefuseToRemoveAMilestoneAPlanClaimsOrAFactUnlockNames() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(rankFour(world), try world.plan(chapter: 4, claims: ["lamp_rank_4"]))
    try await world.refuses(
      #"{"op":"milestone.remove","milestoneKey":"lamp_rank_4"}"#,
      with: .domain(.milestoneReferenced(milestone: "lamp_rank_4", references: ["the plan for chapter 4"])))
    let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("ghost")])])])
    try await world.seed(
      MilestoneRecord(novel: world.novel, milestone: "ghost", label: "Ghost"), SecretRecord(novel: world.novel, secret: "rule", text: "The rule.", unlock: unlock))
    try await world.refuses(
      #"{"op":"milestone.remove","milestoneKey":"ghost"}"#, with: .domain(.milestoneReferenced(milestone: "ghost", references: ["the unlock of fact rule"])))
    try await world.refuses(#"{"op":"milestone.remove","milestoneKey":"never"}"#, with: .domain(.milestoneNotFound("never")))
  }

  // :139
  @Test func shouldRemoveAMilestoneAPromiseNamesAsItsPayoff() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(rankFour(world), ThreadRecord(novel: world.novel, thread: "the-ledger", summary: "Who has the ledger.", payoffMilestone: "lamp_rank_4"))
    _ = try await world.apply(#"{"op":"milestone.remove","milestoneKey":"lamp_rank_4"}"#).get()
    #expect(isRemoved(try await world.milestone("lamp_rank_4")))
  }

  // :147
  @Test func shouldEditOnlyTheAuthoredFieldsOfAMilestoneAndPutThemBackOnRevert() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(world.entity("mira"), rankFour(world, subject: "mira"))
    try await world.applyThenRevert(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","label":"The fourth rung","subjectEntityKey":null}"#) {
      let milestone = live(try await world.milestone("lamp_rank_4"))
      #expect(milestone?.label == "The fourth rung" && milestone?.subject == nil && milestone?.kind == .known(.rank))
    }
    #expect(live(try await world.milestone("lamp_rank_4")) == rankFour(world, subject: "mira"))
  }

  // milestone.handler.ts:39: a restore puts back a subject whose entity has since gone, unchecked
  @Test func shouldRestoreASubjectWhoseEntityIsGoneWithoutCheckingIt() async throws {
    let world = try await StoryWorld.make()
    let mira = world.entity("mira")
    try await world.seed(mira, rankFour(world, subject: "mira"))
    let op = try storyOp(#"{"op":"milestone.remove","milestoneKey":"lamp_rank_4"}"#)
    let step = try await world.apply(op).get()
    _ = try await world.store.write { transaction in try EntityRecord.remove(mira.ref, in: &transaction) }
    _ = try await world.undo(op, try #require(step.inverse)).get()
    #expect(live(try await world.milestone("lamp_rank_4")) == rankFour(world, subject: "mira"))
  }

  // :158
  @Test func shouldRefuseANewMilestoneWithoutALabel() async throws {
    let world = try await StoryWorld.make()
    try await world.refuses(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4"}"#, with: ApplyError.refused(.notAllowed))
    #expect(ApplyRefusal.notAllowed.code == "RFN_004")
  }

  @Test func shouldCreateAMilestoneTrimmedWithItsDefaultKindOrTheOneNamed() async throws {
    let world = try await StoryWorld.make()
    _ = try await world.apply(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","label":"  Mira climbs  "}"#).get()
    #expect(live(try await world.milestone("lamp_rank_4")) == MilestoneRecord(novel: world.novel, milestone: "lamp_rank_4", label: "Mira climbs"))
    _ = try await world.apply(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_5","label":"Fifth","kind":"rank"}"#).get()
    #expect(live(try await world.milestone("lamp_rank_5")) == MilestoneRecord(novel: world.novel, milestone: "lamp_rank_5", label: "Fifth", kind: .known(.rank)))
  }

  // milestone.handler.ts:44: a blank label keeps the one the milestone has; the change-set grammar refuses one, so the op is built directly
  @Test func shouldKeepTheLabelWhenAnEditCarriesABlankOne() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(rankFour(world))
    _ = try await world.apply(try storyRawOp(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","label":"   ","kind":"event"}"#)).get()
    #expect(
      live(try await world.milestone("lamp_rank_4")) == MilestoneRecord(novel: world.novel, milestone: "lamp_rank_4", label: "Mira reaches the fourth rank", kind: .known(.event)))
  }
}

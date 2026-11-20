import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

let storyApplyContext = ApplyContext(novel: SchemaFixture.novel, intent: .apply, now: Date(timeIntervalSince1970: 1_700_000_000))

func storyOp(_ json: String) throws -> ChangeOp {
  try #require(try applyOps(json).first)
}

func storyInverse(_ json: String) throws -> OrderedJSONObject {
  try #require(try OrderedJSON(parsing: json).objectValue)
}

/// An op built without the change-set grammar, for values it refuses or would normalise.
func storyRawOp(_ json: String) throws -> ChangeOp {
  let fields = OpFields(record: try storyInverse(json))
  let type = try #require(fields.string("op").flatMap { OpType(exactly: $0) })
  let operation = try #require(ChangeOperation(type: type, fields: fields))
  return ChangeOp(operation: operation, metadata: OpMetadata(fields))
}

extension StoryWorld {
  func apply(_ json: String) async throws -> Result<AppliedStep, ApplyError> {
    try await apply(try storyOp(json))
  }

  func apply(_ op: ChangeOp) async throws -> Result<AppliedStep, ApplyError> {
    try await store.write { transaction in
      do throws(ApplyError) {
        return .success(try ApplyFrame.perform(.op(op), context: storyApplyContext, in: &transaction))
      } catch {
        return .failure(error)
      }
    }
  }

  /// Runs an inverse through the frame under the refs of the op it undoes, as the undo path does.
  func undo(_ op: ChangeOp, _ inverse: OrderedJSONObject) async throws -> Result<AppliedStep, ApplyError> {
    let context = ApplyContext(novel: novel, intent: .undo, now: storyApplyContext.now)
    return try await store.write { transaction in
      do throws(ApplyError) {
        let step = try ApplyFrame.perform(.op(op), context: context, in: &transaction) { _, context, transaction throws(ApplyError) in
          try StoryHandlers.undo(inverse, context: context, in: &transaction)
        }
        return .success(step)
      } catch {
        return .failure(error)
      }
    }
  }

  /// Apply, undo, redo and undo again: each undo lands on the content the apply found, the redo on what it left.
  @discardableResult
  func roundTrip(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> AppliedStep {
    let op = try storyOp(json)
    let applied = try await apply(op).get()
    #expect(applied.postState != applied.priorState, "\(json) changed nothing", sourceLocation: sourceLocation)
    let undone = try await undo(op, try #require(applied.inverse, sourceLocation: sourceLocation)).get()
    #expect(undone.postState == applied.priorState, "undo of \(json)", sourceLocation: sourceLocation)
    let redone = try await apply(op).get()
    #expect(redone.postState == applied.postState, "redo of \(json)", sourceLocation: sourceLocation)
    let again = try await undo(op, try #require(redone.inverse, sourceLocation: sourceLocation)).get()
    #expect(again.postState == applied.priorState, "second undo of \(json)", sourceLocation: sourceLocation)
    return applied
  }

  func novelRecord() async throws -> NovelRecord? {
    let novel = novel
    return live(try await read { try NovelRecord.read(id: novel, in: $0) })
  }

  func writeCount() async throws -> Int {
    try await pendingChangeCount()
  }
}

@Suite("Story handlers: apply, undo, redo and undo again restore the content hash")
struct StoryHandlerRoundTripTests {
  @Test func shouldRestoreThePremiseFieldsAnUpdateNames() async throws {
    let world = try await StoryWorld.make()
    try await world.roundTrip(#"{"op":"premise.update","premise":"A ferryman.","themes":["debt"],"instructions":"Short lines.","theme":" Trust. ","ending":"x"}"#)
    var record = try #require(try await world.novelRecord())
    #expect(record == NovelRecord(id: world.novel, name: "Ember"))
    let novel = world.novel
    try await world.run { transaction in
      var edit = NovelEdit()
      edit.theme = .set("  Survival  ")
      edit.brief = .set("The brief.")
      edit.writingStyle = .set("  Terse.  ")
      _ = try NovelRecord.edit(id: novel, edit, in: &transaction)
    }
    try await world.roundTrip(#"{"op":"premise.update","theme":"Trust.","brief":"Another brief.","opposition":"The tide.","instructions":"Long."}"#)
    record = try #require(try await world.novelRecord())
    #expect(record.theme == "  Survival  " && record.brief == "The brief." && record.opposition == nil && record.writingStyle == "  Terse.  ")
  }

  @Test func shouldRestoreAVolumeAnUpsertCreatedEditedOrARemovalTookAway() async throws {
    let world = try await StoryWorld.make()
    try await world.roundTrip(#"{"op":"volume.upsert","volumeKey":"v1","ordinal":1,"title":"The Crossing"}"#)
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v2", ordinal: 2, title: "The Flood", objective: "Reach the bank.", goalMet: true))
    try await world.roundTrip(#"{"op":"volume.upsert","volumeKey":"v2","ordinal":5,"objective":"Burn the ferry.","body":"Rain."}"#)
    try await world.roundTrip(#"{"op":"volume.remove","volumeKey":"v2"}"#)
    #expect(live(try await world.volume("v2"))?.goalMet == true)
  }

  @Test func shouldRestoreAMilestoneAnUpsertCreatedEditedOrARemovalTookAway() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(world.entity("mara"))
    try await world.roundTrip(#"{"op":"milestone.upsert","milestoneKey":"rise","label":" Mara rises ","subjectEntityKey":"mara","kind":"rank"}"#)
    try await world.seed(MilestoneRecord(novel: world.novel, milestone: "fall", label: "Mara falls", subject: "mara", kind: .known(.event)))
    try await world.roundTrip(#"{"op":"milestone.upsert","milestoneKey":"fall","label":"The fall","subjectEntityKey":null,"kind":"custom"}"#)
    try await world.roundTrip(#"{"op":"milestone.remove","milestoneKey":"fall"}"#)
  }

  @Test func shouldRestoreAFactAnUpsertCreatedEditedOrARemovalTookAway() async throws {
    let world = try await StoryWorld.make(reconciled: true)
    try await world.roundTrip(#"{"op":"fact.upsert","factKey":"heir","body":"Mara is the heir.","terms":["heir"],"revealChapter":4}"#)
    let dated = SecretRecord(
      novel: world.novel, secret: "vault", text: "The vault is empty.", subjects: ["mara"], constraintNote: "Never say it.", writerNote: "",
      cluesAndTerms: CluesAndTerms(clues: ["dust"], terms: ["empty"]), revealChapter: 12, unlock: .object(["all": .array([.object(["chapter": .int(3)])])]),
      source: .known(.seed))
    try await world.seed(dated)
    try await world.roundTrip(#"{"op":"fact.upsert","factKey":"vault","revealChapter":null,"unlock":null,"allowedClues":null,"writerNote":" Hide it. "}"#)
    try await world.roundTrip(#"{"op":"fact.upsert","factKey":"vault","body":"It was never full.","subjects":["ada"],"allowedClues":["cobwebs"]}"#)
    try await world.roundTrip(#"{"op":"fact.remove","factKey":"vault"}"#)
    #expect(live(try await world.secret("vault")) == dated)
  }

  @Test func shouldRestoreAPromiseACreateMadeOrAnUpdatePayoffOrDropChanged() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(try world.draft(chapter: 5))
    try await world.roundTrip(#"{"op":"promise.create","kind":"thread","key":"ledger","label":"Who has the ledger.","openedChapter":3}"#)
    try await world.roundTrip(#"{"op":"promise.create","kind":"mystery","key":"thief","label":"Who took it?"}"#)
    try await world.seed(
      ThreadRecord(novel: world.novel, thread: "oath", summary: nil, status: ThreadProgress(state: .known(.closed), chapter: 2), payoffVolume: "v1", dormant: true),
      MysteryRecord(novel: world.novel, mystery: "door", question: "Who opened it?", status: MysteryProgress(state: .known(.resolved), chapter: 4)))
    try await world.roundTrip(#"{"op":"promise.update","kind":"thread","key":"oath","label":"The oath.","status":"open"}"#)
    try await world.roundTrip(#"{"op":"promise.update","kind":"mystery","key":"door","status":"paid_off","label":"  "}"#)
    try await world.roundTrip(#"{"op":"promise.set_payoff","kind":"thread","key":"oath","someday":true,"dormant":false}"#)
    try await world.roundTrip(#"{"op":"promise.set_payoff","kind":"mystery","key":"door","payoffMilestoneKey":"rise","payoffWindow":9}"#)
    try await world.roundTrip(#"{"op":"promise.drop","kind":"mystery","key":"door"}"#)
    try await world.roundTrip(#"{"op":"promise.drop","kind":"thread","key":"oath"}"#)
    #expect(
      live(try await world.thread("oath"))
        == ThreadRecord(novel: world.novel, thread: "oath", summary: nil, status: ThreadProgress(state: .known(.closed), chapter: 2), payoffVolume: "v1", dormant: true))
  }

  @Test func shouldKeepAStatusThisVersionDoesNotKnowThroughAnUndo() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "oath", summary: "The oath.", status: ThreadProgress(state: .unknown("simmering"), chapter: 7)))
    try await world.roundTrip(#"{"op":"promise.drop","kind":"thread","key":"oath"}"#)
    #expect(live(try await world.thread("oath"))?.status == ThreadProgress(state: .unknown("simmering"), chapter: 7))
  }
}

@Suite("Story handlers: inverses")
struct StoryInverseTests {
  // proposal-apply-tx.spec.ts:73
  @Test func shouldCaptureARemovedVolumeWithEveryGoalField() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "volume_4", ordinal: 4, title: "The Flood", objective: "Reach the far bank."))
    let step = try await world.apply(#"{"op":"volume.remove","volumeKey":"volume_4"}"#).get()
    let expected = #"{"op":"volume.upsert","volumeKey":"volume_4","ordinal":4,"title":"The Flood","objective":"Reach the far bank.","body":null}"#
    #expect(step.inverse == (try storyInverse(expected)))
    #expect(step.result == nil)
  }

  @Test func shouldCaptureEachInverseInTheShapeTheUndoPathReadsBack() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(
      MilestoneRecord(novel: world.novel, milestone: "rise", label: "Rise", kind: .known(.rank)),
      SecretRecord(novel: world.novel, secret: "vault", text: "Empty.", revealChapter: 12),
      MysteryRecord(novel: world.novel, mystery: "door", question: "Who?", payoffWindow: 3))
    let cases: [(op: String, inverse: String)] = [
      (#"{"op":"volume.upsert","volumeKey":"v9","title":"T"}"#, #"{"op":"volume.remove","volumeKey":"v9"}"#),
      (#"{"op":"milestone.upsert","milestoneKey":"rise","label":"Up"}"#, #"{"op":"milestone.upsert","milestoneKey":"rise","label":"Rise","subjectEntityKey":null,"kind":"rank"}"#),
      (#"{"op":"milestone.upsert","milestoneKey":"fall","label":"Down"}"#, #"{"op":"milestone.remove","milestoneKey":"fall"}"#),
      (
        #"{"op":"fact.upsert","factKey":"vault","revealChapter":30}"#,
        #"{"op":"fact.upsert","factKey":"vault","body":"Empty.","subjects":null,"constraintNote":null,"writerNote":null,"terms":null,"revealChapter":12,"unlock":null,"allowedClues":null}"#
      ),
      (#"{"op":"fact.upsert","factKey":"new","body":"B."}"#, #"{"op":"fact.remove","factKey":"new"}"#),
      (#"{"op":"promise.create","kind":"thread","key":"t","label":"L."}"#, #"{"op":"promise.drop","kind":"thread","key":"t","hardDelete":true}"#),
      (
        #"{"op":"promise.update","kind":"mystery","key":"door","label":"Who, then?"}"#,
        #"{"op":"promise.update","kind":"mystery","key":"door","restoreLabel":"Who?","restoreStatus":"open","restoreChapterColumn":null}"#
      ),
      (
        #"{"op":"promise.set_payoff","kind":"mystery","key":"door","someday":true}"#,
        #"{"op":"promise.set_payoff","kind":"mystery","key":"door","payoffMilestoneKey":null,"payoffVolumeKey":null,"payoffWindow":3,"dormant":false}"#
      ),
    ]
    for (op, inverse) in cases {
      let step = try await world.apply(op).get()
      #expect(step.inverse == (try storyInverse(inverse)), "\(op)")
      #expect(try StoryRestore(try storyInverse(inverse)).json == (try storyInverse(inverse)), "\(inverse)")
    }
  }

  // proposal-apply-story-fields.spec.ts:42
  @Test func shouldUndoAFieldItFilledBackToEmptyAndOneItReplacedBackToWhatItHeld() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { transaction in
      var edit = NovelEdit()
      edit.theme = .set("Survival.")
      _ = try NovelRecord.edit(id: novel, edit, in: &transaction)
    }
    let step = try await world.apply(#"{"op":"premise.update","opposition":"The campus itself.","theme":"Trust."}"#).get()
    #expect(step.inverse == (try storyInverse(#"{"op":"premise.update","theme":"Survival.","opposition":null}"#)))
  }

  @Test func shouldRefuseAnInverseItCannotReadWithoutWriting() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v1", ordinal: 1))
    let op = try storyOp(#"{"op":"volume.remove","volumeKey":"v1"}"#)
    let malformed = [
      #"{"op":"volume.upsert","volumeKey":"v1","ordinal":1.5,"title":null,"objective":null,"body":null}"#,
      #"{"op":"volume.upsert","volumeKey":"v1","ordinal":1,"title":null,"objective":null}"#,
      #"{"op":"premise.update","theme":7}"#, #"{"op":"promise.drop","kind":"thread","key":"t"}"#,
      #"{"op":"promise.update","kind":"saga","key":"t","restoreLabel":null,"restoreStatus":"open","restoreChapterColumn":null}"#,
      #"{"op":"fact.upsert","factKey":"f","body":"B.","subjects":[1],"constraintNote":null,"writerNote":null,"terms":null,"revealChapter":null,"unlock":null,"allowedClues":null}"#,
      #"{"op":"entity.remove","entityKey":"mara"}"#, #"{"op":"milestone.upsert","milestoneKey":"m","label":"L","subjectEntityKey":null}"#, #"{}"#,
    ]
    let before = try await world.writeCount()
    for json in malformed {
      let inverse = try storyInverse(json)
      #expect(throws: ApplyRefusal.malformedInverse, "\(json)") { try StoryRestore(inverse) }
      let outcome = try await world.undo(op, inverse)
      #expect(throws: ApplyError.refused(.malformedInverse), "\(json)") { try outcome.get() }
    }
    #expect(try await world.writeCount() == before)
  }
}

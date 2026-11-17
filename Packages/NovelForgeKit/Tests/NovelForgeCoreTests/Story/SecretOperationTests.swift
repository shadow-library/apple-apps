import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let milestoneUnlock = JSONValue.object(["all": .array([.object(["milestone": "ascends"]), .object(["chapter": 4])])])

@Suite("Secrets")
struct SecretOperationTests {
  @Test
  func shouldCreateASecretWithOnlyItsText() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "Mara is the heir", in: &$0) }
    #expect(live(try await world.secret("kin")) == SecretRecord(novel: novel, secret: "kin", text: "Mara is the heir"))
  }

  @Test
  func shouldCreateASecretWithEveryField() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let changes = SecretChanges(
      subjects: .set(["mara"]), constraintNote: .set("keep it"), writerNote: .set("  a scar  "), terms: .set(["heir"]), allowedClues: .set([" a ", "", "a", "b"]),
      revealChapter: .set(5), unlock: .set(milestoneUnlock))
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "Mara is the heir", changes, in: &$0) }
    #expect(
      live(try await world.secret("kin"))
        == SecretRecord(
          novel: novel, secret: "kin", text: "Mara is the heir", subjects: ["mara"], constraintNote: "keep it", writerNote: "a scar",
          cluesAndTerms: CluesAndTerms(clues: ["a", "b"], terms: ["heir"]), revealChapter: 5, unlock: milestoneUnlock, source: .known(.manual)))
  }

  @Test
  func shouldMergeAnUpsertIntoTheExistingSecretKeepingOmittedFields() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Secrets.upsert(
        novel: novel, secret: "kin", text: "old", SecretChanges(subjects: .set(["mara"]), terms: .set(["heir"]), allowedClues: .set(["scar"]), revealChapter: .set(5)), in: &$0)
    }
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "new", SecretChanges(constraintNote: .set("n")), in: &$0) }
    #expect(
      live(try await world.secret("kin"))
        == SecretRecord(
          novel: novel, secret: "kin", text: "new", subjects: ["mara"], constraintNote: "n", cluesAndTerms: CluesAndTerms(clues: ["scar"], terms: ["heir"]), revealChapter: 5))
  }

  @Test
  func shouldClearFieldsWithNilAndCollapseEmptyCluesAndTerms() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Secrets.upsert(
        novel: novel, secret: "kin", text: "t",
        SecretChanges(subjects: .set(["x"]), terms: .set(["heir"]), allowedClues: .set(["scar"]), revealChapter: .set(5), unlock: .set(milestoneUnlock)),
        in: &$0)
    }
    try await world.run {
      try Secrets.upsert(
        novel: novel, secret: "kin", text: "t", SecretChanges(subjects: .set(nil), terms: .set(nil), allowedClues: .set(nil), revealChapter: .set(nil), unlock: .set(nil)), in: &$0)
    }
    #expect(live(try await world.secret("kin")) == SecretRecord(novel: novel, secret: "kin", text: "t"))
  }

  @Test
  func shouldClearTheWriterNoteWithABlankOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(writerNote: .set("note")), in: &$0) }
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(writerNote: .set("  \n")), in: &$0) }
    #expect(live(try await world.secret("kin"))?.writerNote == nil)
  }

  @Test
  func shouldKeepNewerMembersWhenCluesAndTermsAreCleared() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    let ref = SecretRecord.ref(novel: novel, secret: "kin")
    _ = try await world.store.write { transaction in
      try transaction.set(ref, ["clues_and_terms": .object(["clues": .array(["a"]), "terms": .array(["b"]), "future": .int(1)])])
    }
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(terms: .set(nil), allowedClues: .set(nil)), in: &$0) }
    let kept = live(try await world.secret("kin"))?.cluesAndTerms
    #expect(kept?.unrecognised["future"] == .int(1))
    #expect(kept?.clues == nil && kept?.terms == nil)
  }

  @Test
  func shouldKeepAnEmptyClueListThatWasGiven() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(allowedClues: .set([" ", ""])), in: &$0) }
    #expect(live(try await world.secret("kin"))?.cluesAndTerms == CluesAndTerms(clues: []))
  }

  @Test
  func shouldWriteNothingWhenAnUpsertChangesNothing() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let changes = SecretChanges(subjects: .set(["x"]), allowedClues: .set(["a"]), revealChapter: .set(3), unlock: .set(milestoneUnlock))
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", changes, in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", changes, in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldCreateOverARemovedSecretAsAFreshOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run {
      try Secrets.upsert(novel: novel, secret: "kin", text: "old", SecretChanges(subjects: .set(["x"]), revealChapter: .set(9)), in: &$0)
      try Secrets.remove(novel: novel, secret: "kin", in: &$0)
    }
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "fresh", in: &$0) }
    #expect(live(try await world.secret("kin")) == SecretRecord(novel: novel, secret: "kin", text: "fresh"))
  }

  @Test
  func shouldRefuseAMalformedUnlockWithTheReferenceReasons() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let empty = JSONValue.object(["all": .array([])])
    await world.expect(.unlockMalformed("unlock.all must be a non-empty array")) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(unlock: .set(empty)), in: &$0)
    }
    let twoKeys = JSONValue.object(["all": .array([.object(["chapter": 2, "ending": true]), .object(["chapter": 0])])])
    await world.expect(.unlockMalformed("unlock.all[0] must have exactly one of milestone, volume, chapter, ending; unlock.all[1].chapter must be an integer >= 1")) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(unlock: .set(twoKeys)), in: &$0)
    }
    await world.expect(.unlockMalformed("unlock has unexpected field 'any'")) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(unlock: .set(.object(["all": .array([.object(["ending": true])]), "any": .null]))), in: &$0)
    }
    await world.expect(.unlockMalformed("unlock must be an object")) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(unlock: .set(.string("x"))), in: &$0)
    }
    #expect(try await world.secret("kin") == .absent)
  }

  // fact.service.ts:85: changed clues may not name a give-away term; clues and terms left as they were are not judged again
  @Test
  func shouldRefuseChangedCluesThatNameAGiveawayTerm() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.clueNamesTerm(#""the heir's ring" names "heir""#)) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(terms: .set(["heir"]), allowedClues: .set(["the heir's ring"])), in: &$0)
    }
    #expect(try await world.secret("kin") == .absent)
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(terms: .set(["heir"]), allowedClues: .set(["a seal"])), in: &$0) }
    await world.expect(.clueNamesTerm(#""a seal" names "seal""#)) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(terms: .set(["heir", "seal"])), in: &$0)
    }
    let named = SecretRecord(novel: novel, secret: "old", text: "t", cluesAndTerms: CluesAndTerms(clues: ["the heir's ring"], terms: ["heir"]))
    try await world.seed(named)
    try await world.run { try Secrets.upsert(novel: novel, secret: "old", text: "edited", in: &$0) }
    #expect(live(try await world.secret("old"))?.text == "edited")
  }

  @Test
  func shouldAcceptEveryUnlockTerm() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let unlock = JSONValue.object(["all": .array([.object(["milestone": "m"]), .object(["volume": "v"]), .object(["chapter": 3]), .object(["ending": true])])])
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(unlock: .set(unlock)), in: &$0) }
    #expect(live(try await world.secret("kin"))?.unlock == unlock)
  }

  @Test
  func shouldRefuseABlankTextAndAnEarlyRevealChapter() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.blank(field: "text")) { try Secrets.upsert(novel: novel, secret: "kin", text: "", in: &$0) }
    await world.expect(.belowMinimum(field: "revealChapter", minimum: 1)) {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", SecretChanges(revealChapter: .set(0)), in: &$0)
    }
    await world.expect(.invalidKey(field: "factKey")) { try Secrets.upsert(novel: novel, secret: "", text: "t", in: &$0) }
  }

  @Test
  func shouldRefuseAnUnknownNovelAndNeverWritePartOfAFailedUpsert() async throws {
    let world = try await StoryWorld.make(withNovel: false)
    let novel = world.novel
    await world.expect(.novelNotFound(novel)) { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    #expect(try await world.secret("kin") == .absent)
  }

  @Test
  func shouldRemoveAndRestoreASecretAndHideItsKnowledgeWhileRemoved() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(world.entity("mara"))
    try await world.run {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0)
      try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0)
    }
    func visible() async throws -> Int {
      try await world.read { try CharacterKnowledgeRecord.visible(novel: novel, in: $0).count }
    }
    #expect(try await visible() == 1)
    try await world.run { try Secrets.remove(novel: novel, secret: "kin", in: &$0) }
    #expect(isRemoved(try await world.secret("kin")))
    #expect(try await visible() == 0)
    #expect(live(try await world.knowledge(fact: "kin", entity: "mara")) != nil)
    try await world.run { try Secrets.restore(novel: novel, secret: "kin", in: &$0) }
    #expect(try await visible() == 1)
  }

  @Test
  func shouldRefuseRemovingOrRestoringAMissingSecret() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.secretNotFound("kin")) { try Secrets.remove(novel: novel, secret: "kin", in: &$0) }
    await world.expect(.secretNotFound("kin")) { try Secrets.restore(novel: novel, secret: "kin", in: &$0) }
    try await world.run {
      try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0)
      try Secrets.remove(novel: novel, secret: "kin", in: &$0)
    }
    await world.expect(.secretNotFound("kin")) { try Secrets.remove(novel: novel, secret: "kin", in: &$0) }
  }
}

@Suite("Manual reveals")
struct ManualRevealTests {
  private func world() async throws -> StoryWorld {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(world.entity("mara"))
    try await world.run { try Secrets.upsert(novel: novel, secret: "kin", text: "t", in: &$0) }
    return world
  }

  @Test
  func shouldRevealASecretToACharacter() async throws {
    let world = try await world()
    let novel = world.novel
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, note: "overheard", in: &$0) }
    #expect(
      live(try await world.knowledge(fact: "kin", entity: "mara"))
        == CharacterKnowledgeRecord(novel: novel, fact: "kin", entity: "mara", reveal: ManualReveal(chapter: 3, note: "overheard")))
  }

  @Test
  func shouldCorrectAnEarlierRevealInsteadOfDuplicatingIt() async throws {
    let world = try await world()
    let novel = world.novel
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, note: "a", in: &$0) }
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 5, in: &$0) }
    #expect(live(try await world.knowledge(fact: "kin", entity: "mara"))?.reveal == ManualReveal(chapter: 5, note: nil))
    #expect(try await world.read { try CharacterKnowledgeRecord.listing(novel: novel, in: $0).entries.count } == 1)
  }

  @Test
  func shouldWriteNothingWhenTheRevealIsUnchanged() async throws {
    let world = try await world()
    let novel = world.novel
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0) }
    let before = try await world.pendingChangeCount()
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldRetractAndRevealAgain() async throws {
    let world = try await world()
    let novel = world.novel
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 3, in: &$0) }
    try await world.run { try ManualReveals.retract(novel: novel, secret: "kin", entity: "mara", in: &$0) }
    #expect(isRemoved(try await world.knowledge(fact: "kin", entity: "mara")))
    try await world.run { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 4, in: &$0) }
    #expect(live(try await world.knowledge(fact: "kin", entity: "mara"))?.reveal.chapter == 4)
  }

  @Test
  func shouldTreatRetractingWhatWasNeverRevealedAsDone() async throws {
    let world = try await world()
    let novel = world.novel
    let before = try await world.pendingChangeCount()
    try await world.run { try ManualReveals.retract(novel: novel, secret: "kin", entity: "mara", in: &$0) }
    #expect(try await world.pendingChangeCount() == before)
    #expect(try await world.knowledge(fact: "kin", entity: "mara") == .absent)
  }

  @Test
  func shouldCheckTheSecretBeforeTheEntity() async throws {
    let world = try await world()
    let novel = world.novel
    await world.expect(.secretNotFound("ghost")) { try ManualReveals.reveal(novel: novel, secret: "ghost", entity: "nobody", chapter: 1, in: &$0) }
    await world.expect(.entityUnknown("nobody")) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "nobody", chapter: 1, in: &$0) }
    await world.expect(.secretNotFound("ghost")) { try ManualReveals.retract(novel: novel, secret: "ghost", entity: "mara", in: &$0) }
    await world.expect(.entityUnknown("nobody")) { try ManualReveals.retract(novel: novel, secret: "kin", entity: "nobody", in: &$0) }
  }

  @Test
  func shouldRefuseARemovedSecretOrEntityAndAChapterBelowOne() async throws {
    let world = try await world()
    let novel = world.novel
    await world.expect(.belowMinimum(field: "chapter", minimum: 1)) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 0, in: &$0) }
    try await world.run { try Secrets.remove(novel: novel, secret: "kin", in: &$0) }
    await world.expect(.secretNotFound("kin")) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 1, in: &$0) }
    try await world.run { try Secrets.restore(novel: novel, secret: "kin", in: &$0) }
    _ = try await world.store.write { transaction in try EntityRecord.remove(EntityRecord.ref(novel: novel, entity: "mara"), in: &transaction) }
    await world.expect(.entityUnknown("mara")) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 1, in: &$0) }
  }

  @Test
  func shouldRefuseAnUnknownNovel() async throws {
    let world = try await StoryWorld.make(withNovel: false)
    let novel = world.novel
    await world.expect(.novelNotFound(novel)) { try ManualReveals.reveal(novel: novel, secret: "kin", entity: "mara", chapter: 1, in: &$0) }
    await world.expect(.novelNotFound(novel)) { try ManualReveals.retract(novel: novel, secret: "kin", entity: "mara", in: &$0) }
  }
}

@Suite("Story write transaction")
struct StoryTransactionTests {
  @Test
  func shouldSurfaceATypedDomainErrorAndRollBackEarlierWrites() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    do {
      try await world.store.writeDomain { (transaction: inout WriteTransaction) throws(DomainError) in
        try Volumes.create(novel: novel, volume: "one", in: &transaction)
        try Volumes.create(novel: novel, volume: "one", in: &transaction)
      }
      Issue.record("the duplicate create should have failed")
    } catch {
      #expect(error == .volumeExists("one"))
    }
    #expect(try await world.volume("one") == .absent)
  }

  @Test
  func shouldReturnTheResultOfASuccessfulWrite() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let advance = try await world.store.writeDomain { (transaction: inout WriteTransaction) throws(DomainError) -> VolumeAdvance in
      try Volumes.create(novel: novel, volume: "one", ordinal: 1, in: &transaction)
      try Volumes.create(novel: novel, volume: "two", ordinal: 2, in: &transaction)
      return try Volumes.markGoalMet(novel: novel, volume: "one", in: &transaction)
    }
    #expect(advance == VolumeAdvance(completed: "one", activated: "two"))
  }
}

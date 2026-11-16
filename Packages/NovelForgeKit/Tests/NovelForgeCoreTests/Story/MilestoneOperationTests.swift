import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Milestones")
struct MilestoneOperationTests {
  @Test
  func shouldCreateAMilestoneWithItsDefaults() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "  Mara ascends  ", in: &$0) }
    #expect(live(try await world.milestone("ascends")) == MilestoneRecord(novel: novel, milestone: "ascends", label: "Mara ascends"))
  }

  @Test
  func shouldCreateAMilestoneAboutAnExistingCharacter() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(world.entity("mara"))
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", subject: " mara ", kind: .known(.rank), in: &$0) }
    #expect(live(try await world.milestone("ascends")) == MilestoneRecord(novel: novel, milestone: "ascends", label: "Ascends", subject: "mara", kind: .known(.rank)))
  }

  @Test
  func shouldTreatABlankSubjectAsNone() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", subject: "   ", in: &$0) }
    #expect(live(try await world.milestone("ascends"))?.subject == nil)
  }

  @Test
  func shouldRefuseASubjectThatIsNotALiveEntity() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.milestoneSubjectUnknown("mara")) { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", subject: "mara", in: &$0) }
    let mara = world.entity("mara")
    try await world.seed(mara)
    _ = try await world.store.write { transaction in try EntityRecord.remove(mara.ref, in: &transaction) }
    await world.expect(.milestoneSubjectUnknown("mara")) { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", subject: "mara", in: &$0) }
  }

  @Test
  func shouldRefuseAnUnknownNovel() async throws {
    let world = try await StoryWorld.make(withNovel: false)
    let novel = world.novel
    await world.expect(.novelNotFound(novel)) { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
  }

  @Test
  func shouldRefuseAKeyWithSpacesOrNoCharacters() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    for key in ["", "two words", "tab\there", "no\u{A0}break", "line\nbreak"] {
      await world.expect(.invalidKey(field: "milestoneKey")) { try Milestones.create(novel: novel, milestone: key, label: "Label", in: &$0) }
    }
  }

  @Test
  func shouldRefuseABlankLabel() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.blank(field: "label")) { try Milestones.create(novel: novel, milestone: "ascends", label: " \n ", in: &$0) }
    await world.expect(.blank(field: "label")) { try Milestones.create(novel: novel, milestone: "ascends", label: "", in: &$0) }
  }

  @Test
  func shouldHoldKeyAndLabelToTheirLimitsInCodePoints() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let key = String(repeating: "\u{1F600}", count: 200)
    let label = String(repeating: "\u{1F600}", count: 500)
    try await world.run { try Milestones.create(novel: novel, milestone: key, label: " \(label) ", in: &$0) }
    await world.expect(.tooLong(field: "milestoneKey", limit: 200)) { try Milestones.create(novel: novel, milestone: key + "a", label: "x", in: &$0) }
    await world.expect(.tooLong(field: "label", limit: 500)) { try Milestones.create(novel: novel, milestone: "k", label: label + "a", in: &$0) }
    await world.expect(.tooLong(field: "label", limit: 500)) { try Milestones.edit(novel: novel, milestone: key, MilestoneChanges(label: label + "a"), in: &$0) }
    try await world.run { try Milestones.edit(novel: novel, milestone: key, MilestoneChanges(label: " \(label) "), in: &$0) }
  }

  @Test
  func shouldRefuseAnUnknownKind() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.unknownKind("x_future")) { try Milestones.create(novel: novel, milestone: "k", label: "L", kind: .unknown("x_future"), in: &$0) }
    try await world.run { try Milestones.create(novel: novel, milestone: "k", label: "L", in: &$0) }
    await world.expect(.unknownKind("x_future")) { try Milestones.edit(novel: novel, milestone: "k", MilestoneChanges(kind: .unknown("x_future")), in: &$0) }
  }

  @Test
  func shouldReportReferencesBeforeNotFound() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(try world.plan(chapter: 2, claims: ["ghost"]))
    await world.expect(.milestoneReferenced(milestone: "ghost", references: ["the plan for chapter 2"])) { try Milestones.remove(novel: novel, milestone: "ghost", in: &$0) }
  }

  @Test
  func shouldRefuseADuplicateKeyButReuseARemovedOne() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "First", kind: .known(.rank), in: &$0) }
    await world.expect(.milestoneExists("ascends")) { try Milestones.create(novel: novel, milestone: "ascends", label: "Second", in: &$0) }
    try await world.run { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Third", in: &$0) }
    #expect(live(try await world.milestone("ascends")) == MilestoneRecord(novel: novel, milestone: "ascends", label: "Third"))
  }

  @Test
  func shouldEditLabelSubjectAndKind() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.seed(world.entity("mara"))
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
    try await world.run { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(label: " Ascended ", subject: .set("mara"), kind: .known(.event)), in: &$0) }
    #expect(live(try await world.milestone("ascends")) == MilestoneRecord(novel: novel, milestone: "ascends", label: "Ascended", subject: "mara", kind: .known(.event)))
    try await world.run { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(subject: .set(nil)), in: &$0) }
    #expect(live(try await world.milestone("ascends")) == MilestoneRecord(novel: novel, milestone: "ascends", label: "Ascended", kind: .known(.event)))
  }

  @Test
  func shouldRefuseAnEmptyEditAndABlankLabel() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
    await world.expect(.noChanges) { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(), in: &$0) }
    await world.expect(.blank(field: "label")) { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(label: "  "), in: &$0) }
  }

  @Test
  func shouldRefuseEditingAMissingMilestoneOrAnUnknownSubject() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    await world.expect(.milestoneNotFound("ascends")) { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(label: "x"), in: &$0) }
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
    await world.expect(.milestoneSubjectUnknown("ghost")) { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(subject: .set("ghost")), in: &$0) }
    try await world.run { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    await world.expect(.milestoneNotFound("ascends")) { try Milestones.edit(novel: novel, milestone: "ascends", MilestoneChanges(label: "x"), in: &$0) }
  }

  @Test
  func shouldRemoveAndRestoreAMilestone() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
    try await world.run { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    #expect(isRemoved(try await world.milestone("ascends")))
    await world.expect(.milestoneNotFound("ascends")) { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    try await world.run { try Milestones.restore(novel: novel, milestone: "ascends", in: &$0) }
    #expect(live(try await world.milestone("ascends"))?.label == "Ascends")
    await world.expect(.milestoneNotFound("other")) { try Milestones.restore(novel: novel, milestone: "other", in: &$0) }
  }

  @Test
  func shouldRefuseRemovingAMilestoneAPlanClaims() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    try await world.run { try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0) }
    try await world.seed(try world.plan(chapter: 7, claims: ["ascends"]), try world.plan(chapter: 2, claims: ["other", "ascends"]), try world.plan(chapter: 3, claims: ["other"]))
    await world.expect(.milestoneReferenced(milestone: "ascends", references: ["the plan for chapter 2", "the plan for chapter 7"])) {
      try Milestones.remove(novel: novel, milestone: "ascends", in: &$0)
    }
    #expect(live(try await world.milestone("ascends")) != nil)
  }

  @Test
  func shouldRefuseRemovingAMilestoneASecretUnlockNames() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let unlock = JSONValue.object(["all": .array([.object(["milestone": "ascends"])])])
    let other = JSONValue.object(["all": .array([.object(["milestone": "other"]), .object(["chapter": 3])])])
    try await world.run {
      try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0)
      try Secrets.upsert(novel: novel, secret: "zeta", text: "z", SecretChanges(unlock: .set(unlock)), in: &$0)
      try Secrets.upsert(novel: novel, secret: "alpha", text: "a", SecretChanges(unlock: .set(unlock)), in: &$0)
      try Secrets.upsert(novel: novel, secret: "beta", text: "b", SecretChanges(unlock: .set(other)), in: &$0)
    }
    await world.expect(.milestoneReferenced(milestone: "ascends", references: ["the unlock of fact alpha", "the unlock of fact zeta"])) {
      try Milestones.remove(novel: novel, milestone: "ascends", in: &$0)
    }
  }

  @Test
  func shouldListPlanClaimsBeforeUnlocksAndIgnoreMalformedUnlocksAndRemovedOwners() async throws {
    let world = try await StoryWorld.make()
    let novel = world.novel
    let unlock = JSONValue.object(["all": .array([.object(["milestone": "ascends"])])])
    let plan = try world.plan(chapter: 4, claims: ["ascends"])
    try await world.seed(plan)
    try await world.run {
      try Milestones.create(novel: novel, milestone: "ascends", label: "Ascends", in: &$0)
      try Secrets.upsert(novel: novel, secret: "gone", text: "g", SecretChanges(unlock: .set(unlock)), in: &$0)
      try Secrets.remove(novel: novel, secret: "gone", in: &$0)
    }
    _ = try await world.store.write { transaction in
      try transaction.set(
        SecretRecord.ref(novel: novel, secret: "loose"),
        SecretRecord(novel: novel, secret: "loose", text: "l").storedMembers.merging(["unlock": .object(["all": .array([.object(["milestone": "ascends", "chapter": 2])])])]) {
          _, new in new
        })
    }
    await world.expect(.milestoneReferenced(milestone: "ascends", references: ["the plan for chapter 4"])) { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    _ = try await world.store.write { transaction in try ChapterPlanRecord.remove(plan.ref, in: &transaction) }
    try await world.run { try Milestones.remove(novel: novel, milestone: "ascends", in: &$0) }
    #expect(isRemoved(try await world.milestone("ascends")))
  }
}

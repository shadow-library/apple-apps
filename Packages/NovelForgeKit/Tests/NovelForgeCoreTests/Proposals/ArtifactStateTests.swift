import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func states(_ store: VaultStore, _ refs: [String], novel: UUID = novel) async throws -> [JSString: ArtifactState] {
  try await store.read { try ArtifactStateLoader.states(refs: refs, novel: novel, in: $0) }
}

private func hash(_ store: VaultStore, _ ref: String) async throws -> String? {
  try await states(store, [ref])[JSString(ref)]?.contentHash
}

private func seeded(_ records: any NovelForgeRecord...) async throws -> VaultStore {
  let store = try SchemaFixture.store()
  for record in records { _ = try await store.write { transaction in try record.create(in: &transaction) } }
  return store
}

private func content(_ body: String = "plan") -> ChapterPlanContent { ChapterPlanContent(body: body) }

@Suite("Artifact states")
struct ArtifactStateTests {
  @Test func shouldTreatAbsentAndRemovedRecordsAsMissingAndUnreadableOnesAsUnreadable() async throws {
    let store = try await seeded(
      EntityRecord(novel: novel, entity: "gone", type: .known(.character), name: "Gone"), EntityRecord(novel: novel, entity: "kept", type: .known(.character), name: "Kept"))
    _ = try await store.write { transaction in try EntityRecord.remove(novel: novel, entity: "gone", in: &transaction) }
    let broken = NovelForgeKey.volumeKey(novel: novel, volume: "broken")
    _ = try await store.write { transaction in try transaction.set(broken.ref, ["natural_key": broken.stored, "removed": .bool(false)]) }
    let result = try await states(store, ["entity:kept", "entity:gone", "entity:never", "volume:broken"])
    #expect(result[JSString("entity:kept")]?.exists == true)
    for ref in ["entity:gone", "entity:never"] { #expect(result[JSString(ref)] == .missing) }
    #expect(result[JSString("volume:broken")] == .unreadable)
    #expect(result[JSString("volume:broken")]?.isUnreadable == true)
    let records = try await store.read { try ArtifactStateLoader.currentRecords(refs: ["volume:broken", "entity:kept", "entity:gone"], novel: novel, in: $0) }
    #expect(records.unreadable == [JSString("volume:broken")])
    #expect(records["volume:broken"] == .unreadable)
    #expect(records.exists("volume:broken"))
    #expect(!records.exists("entity:gone"))
  }

  @Test func shouldNeverMatchAnUnreadableStateAgainstAnything() {
    let present = ArtifactState(exists: true, revision: nil, contentHash: "h")
    #expect(!ArtifactState.unreadable.matches(.unreadable))
    #expect(!ArtifactState.missing.matches(.unreadable))
    #expect(!ArtifactState.unreadable.matches(.missing))
    #expect(!present.matches(.unreadable))
    #expect(!ArtifactState.unreadable.matches(present))
    #expect(present.matches(present))
    #expect(ArtifactState.missing.matches(.missing))
    #expect(ArtifactState.unreadable == .unreadable)
  }

  @Test func shouldReturnMissingForRefsThatNameNoArtifact() async throws {
    let store = try await seeded(
      try ChapterPlanRecord(novel: novel, chapter: 1, content: content()), try DraftRecord(novel: novel, chapter: 1, content: DraftContent(body: "b", source: .known(.generated))))
    let refs = [
      "chapter:01", "chapter: 1", "chapter:1.0", "chapter:+1", "chapter:0", "chapter:-1", "chapter:", "chapter:x", "draft:01", "draft:0", "promise:other:a", "promise:thread",
      "doc:world", "doc:nosuch/a", "", "premise ",
    ]
    let result = try await states(store, refs)
    for ref in refs { #expect(result[JSString(ref)] == .missing, "\(ref)") }
    let canonical = try await states(store, ["chapter:1", "draft:1"])
    for state in canonical.values { #expect(state.exists) }
  }

  @Test func shouldReportEveryRequestedRefAndKeepOtherNovelsApart() async throws {
    let other = UUID(uuidString: "6f0c4d1e-0000-4000-8000-000000000002") ?? UUID()
    let store = try await seeded(MilestoneRecord(novel: other, milestone: "m", label: "L"))
    let result = try await states(store, ["milestone:m", "milestone:m", "nothing"])
    #expect(result.count == 2)
    #expect(result[JSString("milestone:m")] == .missing)
    let own = try await states(store, ["milestone:m"], novel: other)
    #expect(own[JSString("milestone:m")]?.exists == true)
  }

  @Test func shouldFindRecordsWhoseKeysAreSpelledDecomposed() async throws {
    let store = try await seeded(EntityRecord(novel: novel, entity: "caf\u{e9}", type: .known(.item), name: "Cafe"))
    let result = try await states(store, ["entity:cafe\u{301}"])
    #expect(result[JSString("entity:cafe\u{301}")]?.exists == true)
  }

  @Test func shouldParseDocRefsAtTheFirstSlashAndPromiseRefsAtTheFirstColon() async throws {
    let store = try await seeded(
      PageRecord(novel: novel, section: .world, slug: "a/b/c", content: PageContent(body: "x")), ThreadRecord(novel: novel, thread: "k:v", summary: "S"))
    let result = try await states(store, ["doc:world/a/b/c", "promise:thread:k:v", "promise:mystery:k:v"])
    #expect(result[JSString("doc:world/a/b/c")]?.exists == true)
    #expect(result[JSString("promise:thread:k:v")]?.exists == true)
    #expect(result[JSString("promise:mystery:k:v")] == .missing)
  }
}

@Suite("Artifact content hashes")
struct ArtifactHashTests {
  @Test func shouldPinTheHashOfEveryArtifactKind() async throws {
    let plan = try ChapterPlanRecord(
      novel: novel, chapter: 2,
      content: ChapterPlanContent(
        title: "T", body: "B", volume: "v1", pov: "mara",
        contract: ChapterContract(pov: ["mara"], learns: [ContractLearn(KnowledgeReveal(entityKey: "mara", factKey: "f"))], claimedMilestones: ["m1"])))
    let store = try await seeded(
      NovelRecord(id: novel, name: "Ember", brief: "b", premise: "p", themes: ["x"], theme: "t", writingStyle: "w"),
      PageRecord(novel: novel, section: .world, slug: "cast", content: PageContent(frontmatter: ["title": .string("Cast"), "n": .int(2)], body: "body")),
      VolumeRecord(novel: novel, volume: "v1", ordinal: 1, title: "Vol", objective: "o", body: "b"), plan,
      try DraftRecord(novel: novel, chapter: 2, content: DraftContent(title: "T", body: "B", summary: "S", source: .known(.generated))),
      EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", status: "alive", notes: "n"),
      SecretRecord(novel: novel, secret: "f", text: "secret", subjects: ["mara"], cluesAndTerms: CluesAndTerms(clues: ["c"], terms: ["t"]), revealChapter: 3),
      MilestoneRecord(novel: novel, milestone: "m1", label: "Rank", subject: "mara", kind: .known(.rank)), ThreadRecord(novel: novel, thread: "debt", summary: "Owes"),
      MysteryRecord(novel: novel, mystery: "fire", question: "Who?"))
    let refs = ["premise", "doc:world/cast", "volume:v1", "chapter:2", "draft:2", "entity:mara", "fact:f", "milestone:m1", "promise:thread:debt", "promise:mystery:fire"]
    let result = try await states(store, refs)
    let golden = [
      "premise": "3a59b3ded10daaa22b7ad85ec4dca37ee5db023674585191f3823da8de4ee4fe",
      "doc:world/cast": "09170b5a7565ed6df6fabd91ec970450fac7fd4d9d4049521f9b83e0e3e09396",
      "volume:v1": "75fe2c8aee58a7583aa774ffd5176600f760beb07a3a1d38e75fd91b904c4324",
      "chapter:2": "dfebc556775e3ca192fd16385153a08a618f89f4c176f2f484573c5e03a74fb4",
      "draft:2": "23a844424a01cf9bcd88ffcfa409326237106c8c14864f5f464a7e3addce54be",
      "entity:mara": "83ce004dcff3442f4f8c16bb06aaf9ddccbe4429572ef11e528e5c8f30e966f8",
      "fact:f": "729383c1d7cfb8970e47d6b5cfa9b7a261268fb6550acc2f55eab45d93d85801",
      "milestone:m1": "b626c9691df8d0019999cdb37d18dd80f66ae056ddcc96b0a24d6a9763a9345a",
      "promise:thread:debt": "08f89c6f58880a44e5f9d38ad9ce4daea649db8dbe8d8973c7e7dc890d973fbf",
      "promise:mystery:fire": "8215ec7dcc52de77bf3b17aeb33c05b9cf75fd8ed7697ba5af7e53b8c3377614",
    ]
    for ref in refs { #expect(result[JSString(ref)]?.contentHash == golden[ref], "\(ref)") }
  }

  @Test func shouldHashThePlanFieldsBriefUpdateWritesBeyondTheReferenceList() async throws {
    let store = try await seeded(try ChapterPlanRecord(novel: novel, chapter: 1, content: content()))
    let base = try await hash(store, "chapter:1")
    let planRef = try ChapterPlanRecord.ref(novel: novel, chapter: 1)
    _ = try await store.write { transaction in try ChapterPlanRecord.revise(planRef, ChapterPlanContent(body: "plan", writeMode: .known(.external)), in: &transaction) }
    let external = try await hash(store, "chapter:1")
    _ = try await store.write { transaction in try ChapterPlanRecord.revise(planRef, ChapterPlanContent(body: "plan", densityRisk: "dense"), in: &transaction) }
    let dense = try await hash(store, "chapter:1")
    _ = try await store.write { transaction in try ChapterPlanRecord.revise(planRef, ChapterPlanContent(body: "plan"), in: &transaction) }
    #expect(Set([base, external, dense]).count == 3)
    #expect(try await hash(store, "chapter:1") == base)
  }

  @Test func shouldHashLearnsEvenWithoutANamedPov() async throws {
    let none = try await seeded(try ChapterPlanRecord(novel: novel, chapter: 1, content: content()))
    let learns = try await seeded(
      try ChapterPlanRecord(
        novel: novel, chapter: 1, content: ChapterPlanContent(body: "plan", contract: ChapterContract(learns: [ContractLearn(KnowledgeReveal(entityKey: "e", factKey: "f"))]))))
    #expect(try await hash(none, "chapter:1") != hash(learns, "chapter:1"))
  }

  @Test func shouldRestoreTheHashWhenAnEditIsUndoneAndChangeItWhenContentChanges() async throws {
    let store = try await seeded(EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", notes: "n"))
    let before = try await hash(store, "entity:mara")
    var edit = EntityEdit()
    edit.notes = .set("changed")
    let change = edit
    _ = try await store.write { transaction in try EntityRecord.edit(novel: novel, entity: "mara", change, in: &transaction) }
    let during = try await hash(store, "entity:mara")
    edit.notes = .set("n")
    let revert = edit
    _ = try await store.write { transaction in try EntityRecord.edit(novel: novel, entity: "mara", revert, in: &transaction) }
    #expect(during != before)
    #expect(try await hash(store, "entity:mara") == before)
  }

  @Test func shouldGiveTwoDevicesTheSameHashForTheSameContent() async throws {
    let first = try await seeded(VolumeRecord(novel: novel, volume: "v", ordinal: 1, title: "T"), MilestoneRecord(novel: novel, milestone: "m", label: "L"))
    let second = try await seeded(MilestoneRecord(novel: novel, milestone: "m", label: "L"), VolumeRecord(novel: novel, volume: "v", ordinal: 1, title: "T"))
    #expect(try await hash(first, "volume:v") == hash(second, "volume:v"))
    #expect(try await hash(first, "milestone:m") == hash(second, "milestone:m"))
  }

  @Test func shouldLeaveTheDerivedVolumeStandingOutOfTheHash() async throws {
    let store = try await seeded(VolumeRecord(novel: novel, volume: "v", ordinal: 1, title: "T"))
    let before = try await hash(store, "volume:v")
    var edit = VolumeEdit()
    edit.goalMet = .set(true)
    let change = edit
    _ = try await store.write { transaction in try VolumeRecord.edit(novel: novel, volume: "v", change, in: &transaction) }
    #expect(try await hash(store, "volume:v") == before)
  }

  @Test func shouldJoinLaterFactAndStoryFieldsToTheHashOnlyOnceTheyHoldAValue() async throws {
    let store = try await seeded(NovelRecord(id: novel, name: "Ember", premise: "p"), SecretRecord(novel: novel, secret: "f", text: "t"))
    let premise = try await hash(store, "premise")
    let fact = try await hash(store, "fact:f")
    var novelEdit = NovelEdit()
    novelEdit.theme = .set("grief")
    var factEdit = SecretEdit()
    factEdit.writerNote = .set("note")
    let (setNovel, setFact) = (novelEdit, factEdit)
    _ = try await store.write { transaction in
      _ = try NovelRecord.edit(id: novel, setNovel, in: &transaction)
      return try SecretRecord.edit(novel: novel, secret: "f", setFact, in: &transaction)
    }
    #expect(try await hash(store, "premise") != premise)
    #expect(try await hash(store, "fact:f") != fact)
    novelEdit.theme = .set(nil)
    factEdit.writerNote = .set(nil)
    let (clearNovel, clearFact) = (novelEdit, factEdit)
    _ = try await store.write { transaction in
      _ = try NovelRecord.edit(id: novel, clearNovel, in: &transaction)
      return try SecretRecord.edit(novel: novel, secret: "f", clearFact, in: &transaction)
    }
    #expect(try await hash(store, "premise") == premise)
    #expect(try await hash(store, "fact:f") == fact)
  }
}

@Suite("Current records")
struct CurrentRecordsTests {
  private func current(_ store: VaultStore, _ refs: [String]) async throws -> CurrentRecords {
    try await store.read { try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: $0) }
  }

  @Test func shouldDeriveTheVolumeStateFromTheVolumesStanding() async throws {
    let store = try await seeded(
      VolumeRecord(novel: novel, volume: "a", ordinal: 1, goalMet: true), VolumeRecord(novel: novel, volume: "b", ordinal: 2), VolumeRecord(novel: novel, volume: "c", ordinal: 3))
    let records = try await current(store, ["volume:a", "volume:b", "volume:c", "volume:z"])
    #expect(records["volume:a"]?.fields?["state"] == OrderedJSON.string("goal_met"))
    #expect(records["volume:b"]?.fields?["state"] == OrderedJSON.string("active"))
    #expect(records["volume:c"]?.fields?["state"] == OrderedJSON.string("not_started"))
    #expect(records["volume:z"] == nil)
  }

  @Test func shouldHoldNoFieldsForChaptersAndDraftsBeyondTheirExistence() async throws {
    let store = try await seeded(
      try ChapterPlanRecord(novel: novel, chapter: 1, content: content()), try DraftRecord(novel: novel, chapter: 1, content: DraftContent(body: "b", source: .known(.generated))))
    let records = try await current(store, ["chapter:1", "draft:1", "chapter:2"])
    #expect(records["chapter:1"] == .fields(OrderedJSONObject([])))
    #expect(records["draft:1"] == .fields(OrderedJSONObject([])))
    #expect(records["chapter:2"] == nil)
  }

  @Test func shouldMapNativeRecordsOntoTheReferenceFieldNames() async throws {
    let store = try await seeded(
      NovelRecord(id: novel, name: "Ember", protagonist: "mara", writingStyle: "plain"),
      SecretRecord(novel: novel, secret: "f", text: "t", cluesAndTerms: CluesAndTerms(clues: ["c"], terms: ["x"])),
      ThreadRecord(novel: novel, thread: "debt", summary: "Owes", dormant: true))
    let records = try await current(store, ["premise", "fact:f", "promise:thread:debt"])
    #expect(records["premise"]?.fields?["instructions"] == OrderedJSON.string("plain"))
    #expect(records["premise"]?.fields?["protagonistKey"] == OrderedJSON.string("mara"))
    #expect(records["fact:f"]?.fields?["body"] == OrderedJSON.string("t"))
    #expect(records["fact:f"]?.fields?["terms"] == OrderedJSON.array([.string("x")]))
    #expect(records["fact:f"]?.fields?["allowedClues"] == OrderedJSON.array([.string("c")]))
    #expect(records["promise:thread:debt"]?.fields?["dormant"] == OrderedJSON.bool(true))
    #expect(records["promise:thread:debt"]?.fields?["lastAdvancedChapter"] == OrderedJSON.null)
  }
}

@Suite("Proposal current")
struct ProposalCurrentTests {
  private func ops(_ text: String) throws -> [ChangeOp] {
    try parseChangeSet(try OrderedJSON(parsing: text), options: ChangeSetValidationOptions(entityMaterialization: false))
  }

  @Test func shouldListCurrentValuesOnlyForTheOpsThatNeedThem() async throws {
    let store = try await seeded(EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", notes: "old"))
    let changeSet = try ops(
      #"[{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"new","rationale":"r"},{"op":"brief.update","chapter":1,"title":"T"},{"op":"entity.upsert","entityKey":"ghost","type":"item","name":"G"}]"#
    )
    #expect(currentRefs(changeSet) == ["entity:mara", "entity:ghost"])
    let refs = currentRefs(changeSet)
    let records = try await store.read { try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: $0) }
    let result = proposalCurrent(changeSet, records: records)
    #expect(result.map(\.index) == [0, 2])
    #expect(result[0].exists)
    #expect(result[0].values == OrderedJSONObject([(key: "type", value: .string("character")), (key: "notes", value: .string("old"))]))
    #expect(!result[1].exists)
    #expect(result[1].values == OrderedJSONObject([]))
  }

  @Test func shouldFlagAnOpWhoseRecordCannotBeRead() async throws {
    let store = try SchemaFixture.store()
    let broken = NovelForgeKey.entityKey(novel: novel, entity: "mara")
    _ = try await store.write { transaction in try transaction.set(broken.ref, ["natural_key": broken.stored, "removed": .bool(false)]) }
    let changeSet = try ops(#"[{"op":"entity.upsert","entityKey":"mara","type":"character","name":"M"}]"#)
    let refs = currentRefs(changeSet)
    let records = try await store.read { try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: $0) }
    let result = proposalCurrent(changeSet, records: records)
    #expect(result.count == 1)
    #expect(records.exists("entity:mara"))
    #expect(result[0].isUnreadable)
    #expect(result[0].values == OrderedJSONObject([]))
  }
}

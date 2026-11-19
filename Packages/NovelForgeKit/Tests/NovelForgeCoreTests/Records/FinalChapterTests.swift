import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let wrong = JSONValue.array([.null])

private func finalChapter(_ chapter: Int = 4, body: String = "Salt.", contract: ChapterContract = ChapterContract(), novel: UUID = novel) throws(NovelForgeKeyError)
  -> FinalChapterRecord
{
  try FinalChapterRecord(
    novel: novel, chapter: chapter,
    canon: Canon(draftRevision: "v:draft", planRevision: "v:plan", approval: SchemaFixture.otherNovel, title: "Harbour", body: body, summary: "They land", contract: contract))
}

private func finalize(_ record: FinalChapterRecord, in store: VaultStore) async throws -> FinalizeOutcome {
  try await store.write { transaction in try record.finalize(in: &transaction) }
}

private func readCanon(_ record: FinalChapterRecord, _ canon: JSONValue, in store: VaultStore) async throws -> RecordReading<FinalChapterRecord> {
  try await SchemaFixture.set(record.ref, ["natural_key": record.key.stored, "canon": canon], in: store)
  return try await Harness.read(record.ref, as: FinalChapterRecord.self, in: store)
}

private func read(_ ref: EntityRef, in store: VaultStore) async throws -> FinalChapterRecord? {
  try await Harness.read(ref, as: FinalChapterRecord.self, in: store).entry?.record
}

private func amend(_ ref: EntityRef, _ text: FinalChapterText, in store: VaultStore) async throws -> Revised {
  try await store.write { transaction in try FinalChapterRecord.amend(ref, text, in: &transaction) }
}

private func pending(in store: VaultStore) async throws -> Int {
  try await store.pendingChanges(limit: Int.max).count
}

private func editThroughTheProtocol<R: NovelForgeRecord>(_: R.Type, _ ref: EntityRef, _ fields: RecordFields<R.Field>, in store: VaultStore) async throws {
  _ = try await store.write { transaction in try R.edit(ref, fields, in: &transaction) }
}

private func canonText(_ canon: Canon) -> FinalChapterText {
  FinalChapterText(title: canon.title, body: canon.body, note: canon.note, summary: canon.summary)
}

private let recordedMembers = Set([FinalChapterCanonMember.disclosed, .review, .knowledge].map(\.rawValue))
private let review = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c1")

private let learning = ChapterContract(
  pov: ["aria"], learns: [ContractLearn(KnowledgeReveal(entityKey: "aria", factKey: "heir"))], claimedMilestones: ["rank-two"], isEnding: false)
private let otherLearning = ChapterContract(
  pov: ["brook"], learns: [ContractLearn(KnowledgeReveal(entityKey: "brook", factKey: "fire"))], claimedMilestones: ["rank-three"], isEnding: true)

@Suite("Final chapters", TestTimeLimit.standard)
struct FinalChapterTests {
  @Test func shouldFinalizeWithOneSetOfTheKeyAndTheWholeCanon() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter(contract: learning)
    #expect(record.ref == record.key.ref)
    #expect(record.ref == (try FinalChapterRecord.ref(novel: novel, chapter: 4)))
    guard case .finalized(let change) = try await finalize(record, in: store) else {
      Issue.record("the first finalize found a canon")
      return
    }
    #expect(change.fields == ["natural_key": record.key.stored, "canon": record.canon.json])
    #expect(try await pending(in: store) == 1)
    expectLive(try await Harness.read(record.ref, as: FinalChapterRecord.self, in: store), record)
    let stored = try #require(try await read(record.ref, in: store))
    #expect(stored.text == FinalChapterText(title: "Harbour", body: "Salt.", summary: "They land"))
    #expect(stored.canonDigest == FinalChapterRecord.digest(record.canon.json))
    #expect(stored.canon.contract.knowledge?.learns == learning.reveals)
    #expect(stored.canon.contract.claimedMilestones == ["rank-two"])
    #expect(try await store.read { transaction in try FinalChapterRecord.history(record.ref, in: transaction) }.history?.revisions == [])
  }

  @Test func shouldFindTheExistingCanonAndWriteNothingOnASecondFinalize() async throws {
    let store = try SchemaFixture.store()
    let first = try finalChapter(body: "first")
    _ = try await finalize(first, in: store)
    let before = try await pending(in: store)
    #expect(try await finalize(try finalChapter(body: "second", contract: learning), in: store) == .alreadyFinal(first))
    #expect(try await pending(in: store) == before)
    expectLive(try await Harness.read(first.ref, as: FinalChapterRecord.self, in: store), first)
  }

  @Test func shouldReportACanonItCannotReadAndWriteNothingOverIt() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter()
    try await SchemaFixture.set(record.ref, ["natural_key": record.key.stored, "canon": "broken"], in: store)
    let keyless = try finalChapter(5)
    try await SchemaFixture.set(keyless.ref, ["canon": keyless.canon.json], in: store)
    let before = try await pending(in: store)
    #expect(try await finalize(record, in: store) == .unreadableCanon(.invalid(field: "canon")))
    #expect(try await finalize(keyless, in: store) == .unreadableCanon(.missing(field: "natural_key")))
    #expect(try await pending(in: store) == before)
  }

  @Test func shouldAmendTheTextAgainstTheCanonAndKeepTheCanon() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter(contract: learning)
    _ = try await finalize(record, in: store)
    let first = FinalChapterText(title: "Harbour", body: "Salt and tar.", note: "Fixed a typo", summary: "They land")
    let second = FinalChapterText(title: "The Harbour", body: "Salt, tar and rope.")
    let revised = try await amend(record.ref, first, in: store)
    #expect(Set(revised.record.fields.keys) == reviseMembers)
    #expect(Set(try #require(revised.record.fields["body"]?.objectValue).keys) == Set(FinalChapterAmendmentMember.allCases.map(\.rawValue)))
    _ = try await amend(record.ref, second, in: store)
    let stored = try #require(try await read(record.ref, in: store))
    #expect(stored.amendment?.text == second)
    #expect(stored.text == second)
    #expect(stored.canon == record.canon)
    let history = try #require(try await store.read { transaction in try FinalChapterRecord.history(record.ref, in: transaction) }.history)
    #expect(history.revisions.map { $0.body.body?.text } == [second, first])
    #expect(history.revisions.allSatisfy { $0.body.body?.canon == record.canonDigest })
  }

  @Test func shouldEditTheSummaryAsAnAmendmentOfTheCurrentText() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter()
    _ = try await finalize(record, in: store)
    let ref = record.ref
    let summarised = try await store.write { transaction in try FinalChapterRecord.editSummary(ref, "They land at dusk", in: &transaction) }
    #expect(Set(summarised.record.fields.keys) == reviseMembers)
    var expected = canonText(record.canon)
    expected.summary = "They land at dusk"
    #expect(try await read(ref, in: store)?.text == expected)

    let amended = FinalChapterText(title: "Harbour", body: "Rope.", summary: "They land at dusk")
    _ = try await amend(ref, amended, in: store)
    _ = try await store.write { transaction in try FinalChapterRecord.editSummary(ref, nil, in: &transaction) }
    let stored = try #require(try await read(ref, in: store))
    #expect(stored.text == FinalChapterText(title: "Harbour", body: "Rope."))
    #expect(stored.canon.summary == "They land")
    #expect(Set(try await SchemaFixture.document(ref, in: store).fields.keys.map(\.value)) == ["natural_key", "canon"])
  }

  @Test func shouldRefuseToAmendOrSummariseAChapterThatIsNotFinal() async throws {
    let store = try SchemaFixture.store()
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: 9)
    await #expect(throws: StoreError.self) { try await amend(ref, FinalChapterText(body: "x"), in: store) }
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try FinalChapterRecord.editSummary(ref, "x", in: &transaction) }
    }
    #expect(try await SchemaFixture.count(.finalChapter, in: store) == 0)
  }

  @Test func shouldRefuseEveryEditOfTheFieldsEvenThroughTheProtocol() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter()
    let ref = try finalChapter(6).ref
    _ = try await finalize(record, in: store)
    let before = try await pending(in: store)
    for field in FinalChapterField.allCases {
      var fields = RecordFields<FinalChapterField>()
      fields.put(field, "x")
      await #expect(throws: StoreError.self) { try await editThroughTheProtocol(FinalChapterRecord.self, record.ref, fields, in: store) }
      await #expect(throws: StoreError.self) { try await editThroughTheProtocol(FinalChapterRecord.self, ref, fields, in: store) }
    }
    #expect(try await pending(in: store) == before)
  }

  @Test func shouldReadAFinalChapterWithoutItsCanonOrKeyAsNotYetPresentAndIgnoreTheSummaryField() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter()
    try await SchemaFixture.set(record.ref, ["summary": "early"], in: store)
    _ = try await SchemaFixture.revise(record.ref, ["body": "unbound"], in: store)
    #expect(try await Harness.read(record.ref, as: FinalChapterRecord.self, in: store) == .absent)
    try await SchemaFixture.set(record.ref, ["natural_key": record.key.stored], in: store)
    #expect(try await Harness.read(record.ref, as: FinalChapterRecord.self, in: store) == .absent)
    let keyless = try finalChapter(5)
    try await SchemaFixture.set(keyless.ref, ["canon": keyless.canon.json], in: store)
    #expect(try await Harness.read(keyless.ref, as: FinalChapterRecord.self, in: store) == .absent)
    let listing = try await store.read { transaction in try FinalChapterRecord.listing(in: transaction) }
    #expect(listing == RecordListing(entries: [], unreadable: 0, unattributed: 0))

    _ = try await finalize(record, in: store)
    expectLive(try await Harness.read(record.ref, as: FinalChapterRecord.self, in: store), record)
    let other = try finalChapter(7)
    try await SchemaFixture.set(other.ref, ["natural_key": other.key.stored, "canon": other.canon.json, "summary": 3], in: store)
    expectLive(try await Harness.read(other.ref, as: FinalChapterRecord.self, in: store), other)
  }

  @Test func shouldFallBackToTheNewestReadableAmendmentBoundToTheCanon() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter()
    _ = try await finalize(record, in: store)
    let digest = JSONValue.string(record.canonDigest)
    let bound = FinalChapterText(body: "bound")
    _ = try await amend(record.ref, bound, in: store)
    _ = try await SchemaFixture.revise(record.ref, ["canon": digest, "title": "no body"], in: store)
    _ = try await SchemaFixture.revise(record.ref, ["body": "no canon"], in: store)
    _ = try await SchemaFixture.revise(record.ref, ["canon": "another canon", "body": "orphan"], in: store)
    var stored = try #require(try await read(record.ref, in: store))
    #expect(stored.text == bound)
    #expect(stored.canon == record.canon)

    _ = try await SchemaFixture.revise(record.ref, ["canon": digest, "body": "newer", "title": nil, "note": nil, "summary": nil, "mood": "dark"], in: store)
    stored = try #require(try await read(record.ref, in: store))
    #expect(stored.text == FinalChapterText(body: "newer"))
    #expect(stored.amendment?.unrecognised == ["mood": "dark"])
    let ref = record.ref
    let summarised = try await store.write { transaction in try FinalChapterRecord.editSummary(ref, "s", in: &transaction) }
    #expect(summarised.record.fields["body"]?.objectValue?["mood"] == "dark")
    #expect(try await read(ref, in: store)?.text == FinalChapterText(body: "newer", summary: "s"))
  }

  @Test func shouldReadACanonTotally() async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter(contract: learning)
    let canon = try #require(record.canon.json.objectValue)
    let required: Set<String> = ["body", "generator", "isolated", "contract"]
    var chapter = 100
    func next() throws -> FinalChapterRecord {
      chapter += 1
      return try finalChapter(chapter)
    }
    for name in canon.keys {
      var missing = canon
      missing[name] = nil
      let afterRemoval = try await readCanon(try next(), .object(missing), in: store)
      if required.contains(name) {
        #expect(afterRemoval == .unreadable(.invalid(field: "canon")), "missing \(name)")
      } else {
        #expect(afterRemoval.entry?.record.canon.json.objectValue?[name] == JSONValue.null, "missing \(name)")
      }
      var corrupt = canon
      corrupt[name] = wrong
      let afterCorruption = try await readCanon(try next(), .object(corrupt), in: store)
      if recordedMembers.contains(name) {
        let read = try #require(afterCorruption.entry?.record.canon, "wrong type \(name)")
        #expect(read.disclosed == nil && read.review == nil && read.knowledge == nil, "wrong type \(name)")
        #expect(read.json.objectValue?[name] == wrong, "wrong type \(name)")
      } else {
        #expect(afterCorruption == .unreadable(.invalid(field: "canon")), "wrong type \(name)")
      }
    }
    var newer = canon
    newer["generator"] = "x_collective"
    newer["word_count"] = 1200
    newer["contract"] = ["pov": [], "learns": [["entity": "a", "fact": "f", "since": 2]], "claimed_milestones": [], "is_ending": false, "stakes": 3]
    let carried = try #require(try await readCanon(try next(), .object(newer), in: store).entry?.record)
    #expect(carried.canon.json == .object(newer))
    #expect(carried.canon.generator == .unknown("x_collective"))
    #expect(carried.canonDigest == FinalChapterRecord.digest(.object(newer)))
    #expect(try await readCanon(try next(), ["body": "b"], in: store) == .unreadable(.invalid(field: "canon")))
    var approval = canon
    approval["approval"] = .string(SchemaFixture.otherNovel.uuidString)
    #expect(try await readCanon(try next(), .object(approval), in: store) == .unreadable(.invalid(field: "canon")))
  }

  @Test func shouldReadAFinalChapterWithAnotherChaptersKeyAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let foreign = try finalChapter(6)
    try await SchemaFixture.set(foreign.ref, ["natural_key": try NovelForgeKey.finalChapterKey(novel: novel, chapter: 60).stored, "canon": foreign.canon.json], in: store)
    guard case .unreadable(.naturalKey) = try await Harness.read(foreign.ref, as: FinalChapterRecord.self, in: store) else {
      Issue.record("another chapter's natural key was accepted")
      return
    }
  }

  @Test func shouldWriteEveryMemberOfACanonAndOnlyTheCanonField() throws {
    let canon = try #require(Canon(body: "b").json.objectValue)
    #expect(Set(canon.keys) == Set(FinalChapterCanonMember.allCases.map(\.rawValue)))
    #expect(canon["disclosed"] == .null)
    let amendment = try #require(FinalChapterAmendment(canon: "c", text: FinalChapterText(body: "b")).json.objectValue)
    #expect(Set(amendment.keys) == Set(FinalChapterAmendmentMember.allCases.map(\.rawValue)))
    #expect(Set(try finalChapter().fields.members.keys) == ["canon"])
  }

  @Test func shouldEncodeTheDisclosedSecretsPrecomposedUniqueAndInUTF16Order() throws {
    let keys = ["b", "Ame\u{301}lie", "Am\u{E9}lie", "a", "b", "\u{FF5E}", "\u{1F600}"]
    let encoded = Canon(body: "b", disclosed: keys).json.objectValue?["disclosed"]
    #expect(encoded == .array(["Am\u{E9}lie", "a", "b", "\u{1F600}", "\u{FF5E}"].map(JSONValue.string)))
    #expect(Canon(body: "b", disclosed: []).json.objectValue?["disclosed"] == .array([]))
  }

  @Test func shouldRoundTripTheDisclosedSecretsThroughFinalize() async throws {
    let store = try SchemaFixture.store()
    var canon = Canon(body: "Salt.", disclosed: ["s:tide", "s:ash", "Ame\u{301}lie"])
    let record = try FinalChapterRecord(novel: novel, chapter: 9, canon: canon)
    guard case .finalized = try await finalize(record, in: store) else { throw SchemaFixtureError(description: "the chapter was not finalized") }
    let stored = try #require(try await read(record.ref, in: store))
    #expect(stored.canon.disclosed == ["Am\u{E9}lie", "s:ash", "s:tide"])
    #expect(stored.canonDigest == record.canonDigest)
    canon.disclosed = []
    let none = try FinalChapterRecord(novel: novel, chapter: 10, canon: canon)
    _ = try await finalize(none, in: store)
    #expect(try await read(none.ref, in: store)?.canon.disclosed == [])
  }

  @Test func shouldRoundTripTheReviewBindingAndTheCommittedKnowledgeThroughFinalize() async throws {
    let store = try SchemaFixture.store()
    let kept: [[String: JSONValue]] = [["category": "appearance", "entityKey": "aria"], ["category": "milestone", "milestoneKey": "rank-two", "reached": true]]
    let pairs = [
      KnowledgeReveal(entityKey: "brook", factKey: "heir"), KnowledgeReveal(entityKey: "aria", factKey: "heir"), KnowledgeReveal(entityKey: "aria", factKey: "fire"),
      KnowledgeReveal(entityKey: "Ame\u{301}lie", factKey: "heir"), KnowledgeReveal(entityKey: "aria", factKey: "heir"),
    ]
    let canon = Canon(body: "Salt.", review: CanonReview(id: review, kept: kept, unreached: ["rank-three", "rank-one", "rank-three"]), knowledge: pairs)
    let record = try FinalChapterRecord(novel: novel, chapter: 13, canon: canon)
    guard case .finalized = try await finalize(record, in: store) else { throw SchemaFixtureError(description: "the chapter was not finalized") }
    let stored = try #require(try await read(record.ref, in: store))
    #expect(stored.canon.review == CanonReview(id: review, kept: kept, unreached: ["rank-one", "rank-three"]))
    #expect(
      stored.canon.knowledge == [
        KnowledgeReveal(entityKey: "aria", factKey: "fire"), KnowledgeReveal(entityKey: "Am\u{E9}lie", factKey: "heir"), KnowledgeReveal(entityKey: "aria", factKey: "heir"),
        KnowledgeReveal(entityKey: "brook", factKey: "heir"),
      ])
    #expect(stored.canonDigest == record.canonDigest)
    let none = try FinalChapterRecord(novel: novel, chapter: 14, canon: Canon(body: "Salt.", knowledge: []))
    _ = try await finalize(none, in: store)
    let empty = try #require(try await read(none.ref, in: store))
    #expect(empty.canon.knowledge == [])
    #expect(empty.canon.review == nil)
  }

  @Test(
    arguments: [
      ("knowledge", "heir"), ("knowledge", [["entity": "aria"]]), ("knowledge", [["entity": "aria", "fact": "heir", "since": 2]]),
      ("knowledge", [["entity": 1, "fact": "heir"]]), ("knowledge", [.null]), ("review", "r"), ("review", ["id": "x", "kept": [], "unreached": []]),
      ("review", ["id": "6f0c4d1e-0000-4000-8000-0000000000c1", "kept": ["appearance"], "unreached": []]),
      ("review", ["id": "6f0c4d1e-0000-4000-8000-0000000000c1", "kept": [], "unreached": [1]]), ("review", ["kept": [], "unreached": []]),
    ] as [(String, JSONValue)])
  func shouldReadAMalformedReviewBindingOrKnowledgeAsNotRecordedAndKeepTheCanonAsStored(_ member: String, _ value: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter(15)
    var canon = try #require(record.canon.json.objectValue)
    canon[member] = value
    let stored = try #require(try await readCanon(record, .object(canon), in: store).entry?.record)
    #expect(stored.canon.review == nil)
    #expect(stored.canon.knowledge == nil)
    #expect(stored.canon.body == "Salt.")
    #expect(stored.canon.json == .object(canon))
    #expect(stored.canonDigest == FinalChapterRecord.digest(.object(canon)))
  }

  @Test func shouldKeepNewerMembersOfTheReviewBindingAndWriteEveryKnownOne() async throws {
    let store = try SchemaFixture.store()
    let binding = try #require(CanonReview(id: review).json.objectValue)
    #expect(Set(binding.keys) == Set(CanonReviewMember.allCases.map(\.rawValue)))
    let record = try finalChapter(16)
    var canon = try #require(record.canon.json.objectValue)
    canon["review"] = ["id": .string(review.uuidString.lowercased()), "kept": [], "unreached": ["b", "a"], "reverted_by": "later"]
    let stored = try #require(try await readCanon(record, .object(canon), in: store).entry?.record)
    #expect(stored.canon.review?.unreached == ["a", "b"])
    #expect(stored.canon.review?.unrecognised == ["reverted_by": "later"])
    #expect(stored.canon.json.objectValue?["review"]?.objectValue?["reverted_by"] == "later")
  }

  @Test func shouldReadAnUnnormalisedDisclosureNormalised() async throws {
    let store = try SchemaFixture.store()
    var canon = try #require(Canon(body: "b").json.objectValue)
    canon["disclosed"] = ["b", "a", "a"]
    let stored = try #require(try await readCanon(try finalChapter(11), .object(canon), in: store).entry?.record)
    #expect(stored.canon.disclosed == ["a", "b"])
  }

  @Test(arguments: [JSONValue.null, "s:ash", 3, true, ["s": "ash"], [1], ["s:ash", .null], [["s:ash"]]])
  func shouldReadAMalformedDisclosureAsNotRecordedAndKeepTheCanonReadable(_ disclosed: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let record = try finalChapter(12)
    var canon = try #require(record.canon.json.objectValue)
    canon["disclosed"] = disclosed
    let stored = try #require(try await readCanon(record, .object(canon), in: store).entry?.record)
    #expect(stored.canon.disclosed == nil)
    #expect(stored.canon.body == "Salt.")
    #expect(stored.canon.json == .object(canon))
    #expect(stored.canonDigest == FinalChapterRecord.digest(.object(canon)))
  }

  @Test func shouldListOnlyTheFinalChaptersOfTheNovel() async throws {
    let store = try SchemaFixture.store()
    let mine = try (1...3).map { chapter throws(NovelForgeKeyError) in try finalChapter(chapter) }
    let theirs = try finalChapter(1, novel: SchemaFixture.otherNovel)
    for record in mine + [theirs] { _ = try await finalize(record, in: store) }
    let listing = try await store.read { transaction in try FinalChapterRecord.listing(novel: novel, in: transaction) }
    #expect(Set(listing.live.map(\.chapter)) == [1, 2, 3])
    #expect(listing.unreadable == 0)
  }

  @Test func shouldDeriveWhatAChapterTeachesFromItsCanonAndNeverFromTheLaterPlanOrDraft() async throws {
    let store = try SchemaFixture.store()
    let plan = try ChapterPlanRecord(novel: novel, chapter: 8, content: ChapterPlanContent(body: "plan", contract: learning))
    let draft = try DraftRecord(novel: novel, chapter: 8, content: DraftContent(body: "draft", source: .known(.generated)))
    _ = try await Harness.create(plan, in: store)
    _ = try await Harness.create(draft, in: store)
    let record = try FinalChapterRecord(novel: novel, chapter: 8, canon: Canon(body: draft.content.body, contract: plan.content.contract))
    _ = try await finalize(record, in: store)

    _ = try await store.write { transaction in
      _ = try ChapterPlanRecord.revise(plan.ref, ChapterPlanContent(body: "replanned", contract: otherLearning), in: &transaction)
      return try DraftRecord.revise(draft.ref, DraftContent(body: "rewritten", source: .known(.revised)), in: &transaction)
    }
    let stored = try #require(try await read(record.ref, in: store))
    #expect(stored.canon.contract == learning)
    #expect(stored.canon.contract.knowledge?.learns == learning.reveals)
    #expect(stored.canon.contract.claimedMilestones == ["rank-two"])
    #expect(stored.canon.contract.isEnding == false)
    #expect(stored.text.body == "draft")
  }
}

@Suite("Final chapters across replicas", TestTimeLimit.standard)
struct FinalChapterReplicaTests {
  @Test func shouldConvergeConcurrentFinalizesOnOneWholeCanon() async throws {
    try await forAll(iterations: 25, seed: 0x2A1) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let candidates = try (0..<replicas.count).map { _ throws(NovelForgeKeyError) in try FinalChapterRecord(novel: id, chapter: 3, canon: Gen.canon(&generator)) }
      var written = [Int: ChangeRecord]()
      for index in (0..<replicas.count).shuffled(using: &generator) {
        if generator.chance(0.5) { await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3))) }
        let candidate = candidates[index]
        let outcome = try await replicas.write(index) { transaction in try candidate.finalize(in: &transaction) }
        if case .finalized(let change) = outcome { written[index] = change }
        for _ in 0..<generator.int(in: 0...3) { _ = try await replicas.step(using: &generator) }
        for reader in 0..<replicas.count {
          guard let seen = try await read(candidates[0].ref, in: await replicas.store(reader))?.canon else { continue }
          #expect(candidates.contains { $0.canon == seen }, "a replica read a canon nobody wrote whole")
        }
      }
      try await replicas.settle()

      let winner = try #require(written.min { $0.value.clock < $1.value.clock })
      let expected = candidates[winner.key]
      try await expectAgreement(expected.ref, as: FinalChapterRecord.self, in: replicas, is: live(expected))
      let stored = try #require(try await read(expected.ref, in: await replicas.store(0)))
      #expect(stored.canon.contract.knowledge?.learns == expected.canon.contract.knowledge?.learns)
      #expect(stored.canon.contract.claimedMilestones == expected.canon.contract.claimedMilestones)
      #expect(stored.canon.contract.isEnding == expected.canon.contract.isEnding)
      #expect(stored.text == canonText(expected.canon))

      let late = candidates[(winner.key + 1) % replicas.count]
      #expect(try await replicas.write(0) { transaction in try late.finalize(in: &transaction) } == .alreadyFinal(expected))
    }
  }

  @Test func shouldKeepTheCanonOfTheEarliestFinalizeWhenEveryReplicaFinalizesBeforeHearingOfTheOthers() async throws {
    try await forAll(iterations: 6, seed: 0x2A4) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let candidates = try (0..<replicas.count).map { _ throws(NovelForgeKeyError) in try FinalChapterRecord(novel: id, chapter: 5, canon: Gen.canon(&generator)) }
      let earliest = generator.int(in: 0...(replicas.count - 1))
      for index in 0..<replicas.count where index != earliest { await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...4))) }
      for index in (0..<replicas.count).shuffled(using: &generator) {
        let candidate = candidates[index]
        let outcome = try await replicas.write(index) { transaction in try candidate.finalize(in: &transaction) }
        guard case .finalized = outcome else {
          Issue.record("replica \(index) heard of another canon before finalizing")
          continue
        }
      }
      try await replicas.settle()
      try await expectAgreement(candidates[0].ref, as: FinalChapterRecord.self, in: replicas, is: live(candidates[earliest]))
    }
  }

  @Test func shouldNeverShowTheAmendmentOrSummaryOfACanonThatLost() async throws {
    try await forAll(iterations: 6, seed: 0x2A2) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let first = try FinalChapterRecord(novel: id, chapter: 2, canon: Gen.canon(&generator))
      let second = try FinalChapterRecord(novel: id, chapter: 2, canon: Gen.canon(&generator))
      let ref = first.ref
      _ = try await replicas.write(0) { transaction in try first.finalize(in: &transaction) }
      await replicas.advanceClock(of: 1, by: .seconds(30))
      _ = try await replicas.write(1) { transaction in try second.finalize(in: &transaction) }
      _ = try await replicas.write(1) { transaction in try FinalChapterRecord.amend(ref, FinalChapterText(body: "B prose, fixed"), in: &transaction) }
      _ = try await replicas.write(1) { transaction in try FinalChapterRecord.editSummary(ref, "B summary", in: &transaction) }
      try await replicas.settle()
      try await expectAgreement(ref, as: FinalChapterRecord.self, in: replicas, is: live(first))
      let history = try #require(try await replicas.store(0).read { transaction in try FinalChapterRecord.history(ref, in: transaction) }.history)
      #expect(history.revisions.count == 2)
      #expect(history.revisions.allSatisfy { $0.body.body?.canon == second.canonDigest })

      let fixed = FinalChapterText(title: "A", body: "A prose, fixed", summary: "A summary")
      _ = try await replicas.write(2) { transaction in try FinalChapterRecord.amend(ref, fixed, in: &transaction) }
      try await replicas.settle()
      for reading in try await readings(ref, as: FinalChapterRecord.self, in: replicas) {
        #expect(reading.entry?.record.text == fixed)
        #expect(reading.entry?.record.canon == first.canon)
      }
    }
  }

  @Test func shouldBindAmendmentsToTheCanonAsStoredNotAsReEncoded() async throws {
    let replicas = try await replicas(seed: 0x2A5)
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 12)
    let stored: JSONValue = [
      "body": "Salt.", "generator": "standard", "isolated": false, "contract": ["pov": [], "learns": [], "claimed_milestones": [], "is_ending": false],
      "word_count": 2,
    ]
    let raw = FinalChapterRecord.digest(stored)
    let reencoded = FinalChapterRecord.digest(try #require(Canon(json: stored)).json)
    #expect(raw != reencoded)
    _ = try await replicas.write(0) { transaction in try transaction.set(key.ref, ["natural_key": key.stored, "canon": stored]) }
    let amended = FinalChapterText(body: "Salt and tar.")
    let first = try await replicas.write(0) { transaction in try FinalChapterRecord.amend(key.ref, amended, in: &transaction) }
    try await replicas.settle()

    let reader = await replicas.store(1)
    var record = try #require(try await read(key.ref, in: reader))
    #expect(record.canonDigest == raw)
    #expect(record.amendment?.canon == raw)
    #expect(record.amendmentRevision == first.revision)
    #expect(record.text == amended)

    let fromElsewhere = try await replicas.write(1) { transaction in
      try transaction.revise(key.ref, body: ["canon": .string(raw), "body": "Salt, tar and rope.", "title": nil, "note": nil, "summary": nil]).revision
    }
    try await replicas.settle()
    record = try #require(try await read(key.ref, in: await replicas.store(0)))
    #expect(record.amendmentRevision == fromElsewhere)
    #expect(record.text == FinalChapterText(body: "Salt, tar and rope."))
  }

  @Test func shouldResolveConcurrentBoundAmendmentsTheSameWayEverywhere() async throws {
    try await forAll(iterations: 8, seed: 0x2A3) { generator in
      let replicas = try await replicas(seed: generator.next())
      let record = try FinalChapterRecord(novel: generator.uuid(), chapter: 1, canon: Gen.canon(&generator))
      _ = try await replicas.write(0) { transaction in try record.finalize(in: &transaction) }
      try await replicas.settle()
      let ref = record.ref
      let (left, right) = (FinalChapterText(body: "left " + Gen.text(&generator)), FinalChapterText(body: "right " + Gen.text(&generator)))
      if generator.chance(0.5) { await replicas.advanceClock(of: 2, by: .seconds(5)) }
      let leftID = try await replicas.write(1) { transaction in try FinalChapterRecord.amend(ref, left, in: &transaction) }.revision
      let rightID = try await replicas.write(2) { transaction in try FinalChapterRecord.amend(ref, right, in: &transaction) }.revision
      try await replicas.settle()
      let all = try await readings(ref, as: FinalChapterRecord.self, in: replicas)
      for reading in all { #expect(reading == all[0]) }
      let winner = rightID.utf8.lexicographicallyPrecedes(leftID.utf8) ? (left, leftID) : (right, rightID)
      #expect(all[0].entry?.record.text == winner.0)
      #expect(all[0].entry?.record.amendmentRevision == winner.1)
      #expect(all[0].entry?.record.canon == record.canon)
    }
  }
}

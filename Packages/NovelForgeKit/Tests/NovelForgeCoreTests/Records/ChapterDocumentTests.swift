import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let wrong = JSONValue.array([.null])

private func readBody<R: ChapterDocument>(_ record: R, _ body: JSONValue, in store: VaultStore) async throws -> RecordReading<R> {
  try await SchemaFixture.set(record.ref, record.storedMembers, in: store)
  _ = try await SchemaFixture.revise(record.ref, body, in: store)
  return try await Harness.read(record.ref, as: R.self, in: store)
}

private func bodyTotality<S: RemovableSubject>(_: S.Type, required: Set<String>, lenient: Set<String> = [], seed: UInt64) async throws
where S.Record: ChapterDocument {
  let store = try SchemaFixture.store()
  try await forAll(iterations: 4, seed: seed) { generator in
    let record = S.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
    let body = try #require(record.content.json.objectValue)
    for name in body.keys {
      var missing = body
      missing[name] = nil
      let afterRemoval = try await readBody(record, .object(missing), in: store)
      if required.contains(name) {
        #expect(afterRemoval == .unreadable(.invalid(field: "head")), "missing \(name)")
      } else {
        #expect(afterRemoval.entry?.record.content.json.objectValue?[name] == JSONValue.null, "missing \(name)")
      }
      var corrupt = body
      corrupt[name] = wrong
      let corrupted = try await readBody(record, .object(corrupt), in: store)
      if lenient.contains(name) {
        #expect(corrupted.entry?.record.content.json == .object(corrupt), "wrong type \(name)")
      } else {
        #expect(corrupted == .unreadable(.invalid(field: "head")), "wrong type \(name)")
      }
    }
    var newer = body
    newer[Harness.newerMember] = ["nested": [1]]
    let carried = try #require(try await readBody(record, .object(newer), in: store).entry?.record)
    #expect(carried.content.json == .object(newer))
  }
}

private func revisedWithNewerMembers<R: ChapterDocument>(_ record: R, newer: JSONValue, edit: (inout R.Body) -> Void, in store: VaultStore) async throws -> JSONValue? {
  _ = try await Harness.create(record, in: store)
  _ = try await SchemaFixture.revise(record.ref, newer, in: store)
  var content = try #require(try await Harness.read(record.ref, as: R.self, in: store).entry?.record.content)
  edit(&content)
  let ref = record.ref
  let revised = try await store.write { [content] transaction in try R.revise(ref, body: content, in: &transaction) }
  return try await SchemaFixture.document(record.ref, in: store).revisions[ExactString(revised.revision)]?.body
}

@Suite("Chapter plans and drafts", .timeLimit(.minutes(5)))
struct ChapterDocumentTests {
  @Test func shouldCreateAndReviseAPlanWithoutTouchingItsDocumentFields() async throws { try await createAndEdit(PlanSubject.self, seed: 0x1A1) }
  @Test func shouldCreateAndReviseADraftWithoutTouchingItsDocumentFields() async throws { try await createAndEdit(DraftSubject.self, seed: 0x1A2) }
  @Test func shouldRemoveRestoreAndRecreateAPlan() async throws { try await removalCycle(PlanSubject.self, seed: 0x1B1) }
  @Test func shouldRemoveRestoreAndRecreateADraft() async throws { try await removalCycle(DraftSubject.self, seed: 0x1B2) }
  @Test func shouldReadAPlanCreatedOverALiveOneFromTheNewestRevision() async throws { try await createOverLiveRecord(PlanSubject.self, seed: 0x1C1) }
  @Test func shouldReadADraftCreatedOverALiveOneFromTheNewestRevision() async throws { try await createOverLiveRecord(DraftSubject.self, seed: 0x1C2) }

  @Test func shouldListOnlyThePlansOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(PlanSubject.self, seed: 0x1D1) }
  @Test func shouldListOnlyTheDraftsOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(DraftSubject.self, seed: 0x1D2) }

  @Test func shouldReadAPlanBodyTotally() async throws {
    try await bodyTotality(PlanSubject.self, required: ["body", "contract", "write_mode", "hand_edited", "inserted"], seed: 0x1E1)
  }
  @Test func shouldReadADraftBodyTotally() async throws {
    try await bodyTotality(DraftSubject.self, required: ["body", "source", "generator", "isolated"], lenient: ["upstream", "state", "run", "job"], seed: 0x1E2)
  }

  @Test func shouldDeriveEachRefFromTheKeyAndRefuseAChapterBelowOne() throws {
    let plan = try ChapterPlanRecord(novel: novel, chapter: 4, content: ChapterPlanContent(body: "b"))
    let draft = try DraftRecord(novel: novel, chapter: 4, content: DraftContent(body: "b", source: .known(.handEdited)))
    #expect(plan.ref == plan.key.ref)
    #expect(draft.ref == draft.key.ref)
    #expect(plan.ref == (try ChapterPlanRecord.ref(novel: novel, chapter: 4)))
    #expect(draft.ref == (try DraftRecord.ref(novel: novel, chapter: 4)))
    #expect(plan.ref != draft.ref)
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(0)) { try ChapterPlanRecord(novel: novel, chapter: 0, content: ChapterPlanContent(body: "b")) }
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(-1)) { try DraftRecord.ref(novel: novel, chapter: -1) }
  }

  @Test func shouldReadAPlanAndADraftAsNotYetPresentUntilBothHalvesOfTheirCreateHaveArrived() async throws {
    let plan = try ChapterPlanRecord(novel: novel, chapter: 2, content: ChapterPlanContent(body: "whole", contract: ChapterContract(pov: ["aria"])))
    try await splitDelivery(plan, in: [[0, 1], [1, 0]], as: ChapterPlanRecord.self)
    let draft = try DraftRecord(novel: novel, chapter: 2, content: DraftContent(body: "whole", source: .known(.generated)))
    try await splitDelivery(draft, in: [[0, 1], [1, 0]], as: DraftRecord.self)
  }

  @Test func shouldMoveMarksWithoutMovingTheHead() async throws {
    let store = try SchemaFixture.store()
    let draft = try DraftRecord(novel: novel, chapter: 3, content: DraftContent(body: "v0", source: .known(.generated)))
    _ = try await Harness.create(draft, in: store)
    let ref = draft.ref
    let approved = try await store.write { transaction in
      try DraftRecord.revise(ref, DraftContent(body: "v1", source: .known(.revised)), marks: [.approved], in: &transaction)
    }
    let later = try await store.write { transaction in try DraftRecord.revise(ref, DraftContent(body: "v2", source: .known(.handEdited)), in: &transaction) }
    var history = try #require(try await store.read { transaction in try DraftRecord.history(ref, in: transaction) }.history)
    #expect(history.marks == [.approved: approved.revision])
    #expect(history.head == later.revision)

    let marked = try await store.write { [later] transaction in try DraftRecord.mark(ref, revision: later.revision, [.approved], in: &transaction) }
    #expect(marked.fields["head"] == .bool(false))
    history = try #require(try await store.read { transaction in try DraftRecord.history(ref, in: transaction) }.history)
    #expect(history.marks == [.approved: later.revision])
    #expect(history.head == later.revision)
    #expect(history.revisions.count == 3)

    let plan = try ChapterPlanRecord(novel: novel, chapter: 3, content: ChapterPlanContent(body: "p0"))
    _ = try await Harness.create(plan, in: store)
    let head = try #require(try await store.read { transaction in try ChapterPlanRecord.history(plan.ref, in: transaction) }.history?.head)
    _ = try await store.write { transaction in try ChapterPlanRecord.mark(plan.ref, revision: head, [.finalized], in: &transaction) }
    #expect(try await store.read { transaction in try ChapterPlanRecord.history(plan.ref, in: transaction) }.history?.marks == [.finalized: head])
  }

  @Test func shouldRefuseToMarkARevisionOfAnotherKindOrOneThatDoesNotExist() async throws {
    let store = try SchemaFixture.store()
    let draft = try DraftRecord(novel: novel, chapter: 3, content: DraftContent(body: "v0", source: .known(.generated)))
    _ = try await Harness.create(draft, in: store)
    let head = try #require(try await store.read { transaction in try DraftRecord.history(draft.ref, in: transaction) }.history?.head)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try ChapterPlanRecord.mark(draft.ref, revision: head, [.finalized], in: &transaction) }
    }
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try DraftRecord.mark(draft.ref, revision: "v:missing", [.approved], in: &transaction) }
    }
    let before = try await store.pendingChanges(limit: Int.max).count
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try DraftRecord.mark(draft.ref, revision: head, [], in: &transaction) }
    }
    #expect(try await store.pendingChanges(limit: Int.max).count == before)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        try DraftRecord.revise(ChapterPlanRecord.ref(novel: novel, chapter: 3), DraftContent(body: "x", source: .known(.generated)), in: &transaction)
      }
    }
  }

  @Test func shouldCarryNewerMembersOfAPlanAndItsNestedValuesThroughARevision() async throws {
    let store = try SchemaFixture.store()
    let plan = try ChapterPlanRecord(novel: novel, chapter: 5, content: ChapterPlanContent(body: "p"))
    let newer: JSONValue = [
      "body": "p", "contract": ["pov": ["aria"], "learns": [["entity": "aria", "fact": "heir", "since": "birth"]], "claimed_milestones": [], "is_ending": false, "stakes": 2],
      "ending_contract": ["hook_type": "x_twist", "emotional_beat": "e", "open_question": "q", "handoff_state": "h", "tone": "dark"],
      "scenes": [["summary": "s", "pov": nil, "location": "harbour"]], "write_mode": "x_collaborative", "hand_edited": false, "inserted": false, "tempo": "fast",
    ]
    let stored = try await revisedWithNewerMembers(plan, newer: newer, edit: { $0.title = "Edited" }, in: store)
    let object = try #require(stored?.objectValue)
    #expect(object["tempo"] == "fast")
    #expect(object["title"] == "Edited")
    #expect(object["write_mode"] == "x_collaborative")
    #expect(object["contract"]?.objectValue?["stakes"] == 2)
    #expect(object["ending_contract"]?.objectValue?["tone"] == "dark")
    #expect(object["ending_contract"]?.objectValue?["hook_type"] == "x_twist")
    #expect(object["scenes"]?.arrayValue?.first?.objectValue?["location"] == "harbour")
    let learn: JSONValue = ["entity": "aria", "fact": "heir", "since": "birth"]
    #expect(object["contract"]?.objectValue?["learns"] == [learn])

    let read = try #require(try await Harness.read(plan.ref, as: ChapterPlanRecord.self, in: store).entry?.record)
    #expect(read.content.contract.reveals == [KnowledgeReveal(entityKey: "aria", factKey: "heir")])
    let final = try FinalChapterRecord(novel: novel, chapter: 5, canon: Canon(body: "prose", contract: read.content.contract))
    _ = try await store.write { transaction in try final.finalize(in: &transaction) }
    let canon = try #require(try await SchemaFixture.document(final.ref, in: store)[field: "canon"]?.value.objectValue)
    #expect(canon["contract"]?.objectValue?["learns"] == [learn])
  }

  @Test func shouldKeepADraftReadableAndItsUpstreamAsStoredWhenThisVersionCannotReadTheUpstream() async throws {
    let store = try SchemaFixture.store()
    let draft = try DraftRecord(novel: novel, chapter: 5, content: DraftContent(body: "d", source: .known(.generated)))
    let newer: JSONValue = ["chapters": [["chapter": 1, "inserted": true]]]
    var body = try #require(draft.content.json.objectValue)
    body["upstream"] = newer
    let read = try #require(try await readBody(draft, .object(body), in: store).entry?.record.content)
    #expect(read.body == "d")
    #expect(read.upstream == nil)
    var edited = read
    edited.body = "edited"
    #expect(edited.json.objectValue?["upstream"] == newer)
    edited.upstream = DraftUpstream(entries: [])
    #expect(edited.json.objectValue?["upstream"] == ["chapters": []])
  }

  @Test func shouldRoundTripTheContinuationStateRunAndJobOfADraftRevision() async throws {
    let store = try SchemaFixture.store()
    let job = try JobKey(scope: novel.uuidString.lowercased(), kind: "generate", target: "chapter:5", fingerprint: "f0", run: 1).ref.key
    let content = DraftContent(body: "d", source: .known(.generated), isolated: true, state: ["location": "harbour", "open": ["the locket"]], run: "run-7", job: job)
    let draft = try DraftRecord(novel: novel, chapter: 5, content: content)
    _ = try await Harness.create(draft, in: store)
    let read = try #require(try await Harness.read(draft.ref, as: DraftRecord.self, in: store).entry?.record.content)
    #expect(read == content)
    #expect(read.state == ["location": "harbour", "open": ["the locket"]])
    #expect(read.run == "run-7")
    #expect(read.job == job)
    let ref = draft.ref
    var next = read
    next.body = "edited"
    next.state = nil
    _ = try await store.write { [next] transaction in try DraftRecord.revise(ref, next, in: &transaction) }
    let revised = try #require(try await Harness.read(draft.ref, as: DraftRecord.self, in: store).entry?.record.content)
    #expect(revised.state == nil)
    #expect(revised.json.objectValue?["state"] == .null)
    #expect(revised.job == job)
  }

  @Test(arguments: [("state", ["harbour"]), ("state", "harbour"), ("run", 7), ("job", "not a key"), ("job", ["id": "x"])] as [(String, JSONValue)])
  func shouldKeepADraftReadableAndAMemberAsStoredWhenThisVersionCannotReadIt(_ member: String, _ stored: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let draft = try DraftRecord(novel: novel, chapter: 5, content: DraftContent(body: "d", source: .known(.generated)))
    var body = try #require(draft.content.json.objectValue)
    body[member] = stored
    let read = try #require(try await readBody(draft, .object(body), in: store).entry?.record.content)
    #expect(read.body == "d")
    #expect(read.state == nil && read.run == nil && read.job == nil)
    #expect(read.json == .object(body))
  }

  @Test func shouldCarryNewerMembersOfADraftThroughARevision() async throws {
    let store = try SchemaFixture.store()
    let draft = try DraftRecord(novel: novel, chapter: 5, content: DraftContent(body: "d", source: .known(.generated)))
    let newer: JSONValue = ["body": "d", "source": "x_dictated", "generator": "human", "isolated": true, "rating": ["violence": "mild"]]
    let stored = try await revisedWithNewerMembers(draft, newer: newer, edit: { $0.body = "edited" }, in: store)
    #expect(
      stored == [
        "body": "edited", "source": "x_dictated", "generator": "human", "isolated": true, "rating": ["violence": "mild"], "title": nil, "summary": nil, "restored_from": nil,
        "upstream": nil, "state": nil, "run": nil, "job": nil,
      ])
  }

  @Test(arguments: [
    JSONValue.object(["pov": ["a"], "learns": [["entity": "a"]], "claimed_milestones": [], "is_ending": false]),
    ["pov": ["a"], "learns": [], "claimed_milestones": [], "is_ending": "no"], ["pov": "a", "learns": [], "claimed_milestones": [], "is_ending": false],
    ["learns": [], "claimed_milestones": [], "is_ending": false],
  ])
  func shouldReadAPlanWithAMalformedContractAsUnreadable(_ contract: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let plan = try ChapterPlanRecord(novel: novel, chapter: 6, content: ChapterPlanContent(body: "p"))
    var body = try #require(plan.content.json.objectValue)
    body["contract"] = contract
    #expect(try await readBody(plan, .object(body), in: store) == .unreadable(.invalid(field: "head")))
  }

  @Test(arguments: [JSONValue.array([["pov": "a"]]), [["summary": 3]], [["summary": "s", "beats": "b"]], ["summary": "s"]])
  func shouldReadAPlanWithMalformedScenesAsUnreadable(_ scenes: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let plan = try ChapterPlanRecord(novel: novel, chapter: 6, content: ChapterPlanContent(body: "p"))
    var body = try #require(plan.content.json.objectValue)
    body["scenes"] = scenes
    #expect(try await readBody(plan, .object(body), in: store) == .unreadable(.invalid(field: "head")))
  }

  @Test func shouldTurnTheKnowledgeContractOffWithoutAPointOfView() {
    let reveals = [KnowledgeReveal(entityKey: "aria", factKey: "heir")]
    let learns = reveals.map(ContractLearn.init)
    #expect(ChapterContract(pov: [], learns: learns).knowledge == nil)
    #expect(ChapterContract(pov: [""], learns: learns).knowledge == nil)
    #expect(ChapterContract(pov: ["", "aria"], learns: learns).knowledge == KnowledgeContract(pov: ["aria"], learns: reveals))
  }

  @Test func shouldReadHandWrittenPlanAndDraftBodiesFromTheMemberNames() async throws {
    let store = try SchemaFixture.store()
    let plan = try ChapterPlanRecord(novel: novel, chapter: 7, content: ChapterPlanContent(body: "x"))
    let planBody: JSONValue = [
      "title": "Harbour", "body": "They land.", "volume": "book-one", "context_refs": ["harbour"], "pov": "aria",
      "ending_contract": ["hook_type": "cliffhanger", "emotional_beat": "dread", "open_question": "who", "handoff_state": "docked", "must_not_resolve": ["heir"]],
      "contract": ["pov": ["aria"], "learns": [["entity": "aria", "fact": "heir"]], "claimed_milestones": ["rank-two"], "is_ending": true], "chapter_purpose": "arrive",
      "reader_value": ["mystery"], "repetition_risks": nil, "density_risk": nil, "guidance": "slow", "direction": nil, "content_mode": "unrestricted",
      "scenes": [["summary": "Docking", "pov": "aria", "estimated_words": 900]], "write_mode": "external", "hand_edited": true, "inserted": false,
    ]
    let expectedPlan = ChapterPlanContent(
      title: "Harbour", body: "They land.", volume: "book-one", contextRefs: ["harbour"], pov: "aria",
      endingContract: ChapterEndingContract(hookType: .known(.cliffhanger), emotionalBeat: "dread", openQuestion: "who", handoffState: "docked", mustNotResolve: ["heir"]),
      contract: ChapterContract(pov: ["aria"], learns: [ContractLearn(KnowledgeReveal(entityKey: "aria", factKey: "heir"))], claimedMilestones: ["rank-two"], isEnding: true),
      chapterPurpose: "arrive", readerValue: ["mystery"], guidance: "slow", contentMode: .known(.unrestricted),
      scenes: [PlanScene(BriefScene(summary: "Docking", pov: "aria", estimatedWords: 900))], writeMode: .known(.external), handEdited: true)
    #expect(try await readBody(plan, planBody, in: store).entry?.record.content == expectedPlan)

    let draft = try DraftRecord(novel: novel, chapter: 7, content: DraftContent(body: "x", source: .known(.generated)))
    let draftBody: JSONValue = [
      "title": "Harbour", "body": "Salt.", "summary": "They land", "source": "passage_rewritten", "generator": "unrestricted", "isolated": true, "restored_from": "v:abc",
    ]
    let expectedDraft = DraftContent(
      title: "Harbour", body: "Salt.", summary: "They land", source: .known(.passageRewritten), generator: .known(.unrestricted), isolated: true, restoredFrom: "v:abc")
    #expect(try await readBody(draft, draftBody, in: store).entry?.record.content == expectedDraft)
  }

  @Test func shouldWriteEveryMemberOfAPlanAndADraftBody() throws {
    let plan = try #require(ChapterPlanContent(body: "b").json.objectValue)
    #expect(Set(plan.keys) == Set(ChapterPlanContentMember.allCases.map(\.rawValue)))
    let contract = try #require(ChapterContract().json.objectValue)
    #expect(Set(contract.keys) == Set(CanonContractMember.allCases.map(\.rawValue)))
    let ending = try #require(ChapterEndingContract(hookType: .known(.turn), emotionalBeat: "e", openQuestion: "q", handoffState: "h").json.objectValue)
    #expect(Set(ending.keys) == Set(EndingContractMember.allCases.map(\.rawValue)))
    let scene = try #require(PlanScene(BriefScene(summary: "s")).json.objectValue)
    #expect(Set(scene.keys) == Set(PlanSceneMember.allCases.map(\.rawValue)))
    let learn = try #require(ContractLearn(KnowledgeReveal(entityKey: "a", factKey: "f")).json.objectValue)
    #expect(Set(learn.keys) == Set(CanonLearnMember.allCases.map(\.rawValue)))
    let draft = try #require(DraftContent(body: "b", source: .known(.generated)).json.objectValue)
    #expect(Set(draft.keys) == Set(DraftContentMember.allCases.map(\.rawValue)))
  }

  @Test func shouldConvergeConcurrentDraftRevisionsAndKeepBothInTheHistory() async throws {
    try await forAll(iterations: 6, seed: 0x1F1) { generator in
      let replicas = try await replicas(seed: generator.next())
      let draft = DraftSubject.random(&generator, novel: generator.uuid(), key: Gen.key(&generator))
      _ = try await replicas.write(0) { transaction in try draft.create(in: &transaction) }
      try await replicas.settle()
      let (left, right) = (Gen.draftContent(&generator), Gen.draftContent(&generator))
      let ref = draft.ref
      _ = try await replicas.write(1) { transaction in try DraftRecord.revise(ref, left, marks: [.approved], in: &transaction) }
      await replicas.advanceClock(of: 2, by: .seconds(5))
      _ = try await replicas.write(2) { transaction in try DraftRecord.revise(ref, right, in: &transaction) }
      try await replicas.settle()
      var histories = [HistoryReading<DraftContent, DraftMark>]()
      for index in 0..<replicas.count { histories.append(try await replicas.store(index).read { transaction in try DraftRecord.history(ref, in: transaction) }) }
      for history in histories.dropFirst() { #expect(history == histories[0]) }
      let history = try #require(histories[0].history)
      #expect(history.headEntry?.body == .readable(right))
      let approved = try #require(history.marks[.approved])
      #expect(history.revisions.first { $0.id == approved }?.body == .readable(left))
      try await expectAgreement(ref, as: DraftRecord.self, in: replicas, is: live(draft.with(right)))
    }
  }
}

@Suite("Chapter plans and drafts across replicas", .timeLimit(.minutes(5)))
struct ChapterDocumentReplicaTests {
  @Test func shouldLetAPlanRemovalWithALaterClockWinOverARevision() async throws { try await removalWinsOverAnEditWithAnEarlierClock(PlanSubject.self, seed: 0x111) }
  @Test func shouldLetADraftRemovalWithALaterClockWinOverARevision() async throws { try await removalWinsOverAnEditWithAnEarlierClock(DraftSubject.self, seed: 0x112) }
  @Test func shouldKeepARemovedPlanRemovedWhenARevisionFollowsAndRestoreItOnlyOnRestore() async throws {
    try await anEditAfterARemovalDoesNotRevive(PlanSubject.self, seed: 0x121)
  }
  @Test func shouldKeepARemovedDraftRemovedWhenARevisionFollowsAndRestoreItOnlyOnRestore() async throws {
    try await anEditAfterARemovalDoesNotRevive(DraftSubject.self, seed: 0x122)
  }
  @Test func shouldTakeThePlanFromTheRevisionWithTheLaterClock() async throws { try await fieldsEditedOnDifferentReplicasMerge(PlanSubject.self, seed: 0x131) }
  @Test func shouldTakeTheDraftFromTheRevisionWithTheLaterClock() async throws { try await fieldsEditedOnDifferentReplicasMerge(DraftSubject.self, seed: 0x132) }
  @Test func shouldTakeAConcurrentlyCreatedPlanWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(PlanSubject.self, seed: 0x141) }
  @Test func shouldTakeAConcurrentlyCreatedDraftWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(DraftSubject.self, seed: 0x142) }
}

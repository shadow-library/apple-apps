import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel
private let review = SchemaFixture.review
private let revision = SchemaFixture.draftRevision

private func appendRaw(_ ref: EntityRef, _ item: [String: JSONValue], in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.append(ref, item: item) }
}

private func readAppended<R: AppendedRecord>(_ ref: EntityRef, as _: R.Type, in store: VaultStore) async throws -> AppendedReading<R> {
  try await store.read { transaction in try R.read(ref, in: transaction) }
}

private func remedy(_ action: ReviewRemedyAction, reason: String? = nil) -> ReviewRemedy {
  ReviewRemedy(action: .known(action), fingerprint: "fp-1", reason: reason)
}

private func answer(_ decision: FinalizeDecision, digest: String, reason: String? = nil, edit: [String: JSONValue]? = nil) -> StoredFinalizeAnswer {
  StoredFinalizeAnswer(decision: .known(decision), proposalDigest: digest, edit: edit, reason: reason)
}

private func decision(chapter: Int = 3, draftRevision: String = revision, item: String = "entity:aria", _ answer: StoredFinalizeAnswer, novel: UUID = novel) throws
  -> FinalizeDecisionRecord
{
  try FinalizeDecisionRecord(novel: novel, chapter: chapter, draftRevision: draftRevision, item: item, answer: answer)
}

@Suite("Review and finalize records", .timeLimit(.minutes(3)))
struct ReviewRecordTests {
  @Test func shouldRefuseRepeatedFindingIdsAndItemKeysAndReadStoredRepeatsAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A1)
    let findings = [Gen.finding(&generator, id: "\u{E9}"), Gen.finding(&generator, id: "e\u{301}")]
    #expect(throws: ReviewRecordError.duplicateFinding("e\u{301}")) {
      try ChapterReviewRecord(novel: novel, chapter: 2, reviewKind: .known(.judge), draftRevision: nil, bodyHash: "h", disposition: .known(.issues), findings: findings)
    }
    let reviewRecord = Gen.chapterReview(&generator, novel: novel)
    var item = reviewRecord.item
    item["findings"] = .array(findings.map(\.json))
    try await appendRaw(reviewRecord.ref, item, in: store)
    #expect(try await readAppended(reviewRecord.ref, as: ChapterReviewRecord.self, in: store) == .unreadable(.invalid(field: "findings")))

    let items = [Gen.finalizeItem(&generator, key: "entity:aria", position: 0), Gen.finalizeItem(&generator, key: "entity:aria", position: 1)]
    #expect(throws: ReviewRecordError.duplicateItem("entity:aria")) {
      try FinalizeReviewRecord(
        attempt: Gen.attempt(&generator), job: Gen.jobKey(&generator), novel: novel, chapter: 2, draftRevision: revision, sourceHash: "s", planHash: nil, isolated: false,
        items: items)
    }
    let finalizeReview = Gen.finalizeReview(&generator, novel: novel)
    item = finalizeReview.item
    item["items"] = .array(items.map(\.json))
    try await appendRaw(finalizeReview.ref, item, in: store)
    #expect(try await readAppended(finalizeReview.ref, as: FinalizeReviewRecord.self, in: store) == .unreadable(.invalid(field: "items")))
  }

  @Test func shouldAnswerAnItemWhoseKeyArrivedDecomposed() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A7)
    let decomposed = "appearance:Ame\u{301}lie"
    var stored = Gen.finalizeItem(&generator, key: decomposed, position: 0).json.objectValue ?? [:]
    stored["key"] = .string(decomposed)
    stored["category"] = "appearance"
    stored["triage"] = "consequential"
    stored["basis"] = "observed"
    stored["auto_decision"] = nil
    stored["proposed"] = ["category": "appearance", "entityKey": "Ame\u{301}lie"]
    let record = Gen.finalizeReview(&generator, novel: novel, chapter: 3)
    var item = record.item
    item["items"] = [.object(stored)]
    try await appendRaw(record.ref, item, in: store)
    let read = try #require(try await readAppended(record.ref, as: FinalizeReviewRecord.self, in: store).entry?.record.items.first)
    #expect(read.key == "appearance:Am\u{E9}lie")
    let proposed = try #require(ProposedChange(json: .object(read.proposed)))
    let answered = try decision(draftRevision: record.draftRevision, item: decomposed, answer(.kept, digest: proposed.digest))
    _ = try await Harness.create(answered, in: store)
    let answers = try await store.read { transaction in try FinalizeDecisionRecord.listing(novel: novel, chapter: 3, in: transaction) }.live
    let reviewItem = FinalizeReviewItem(
      itemKey: read.key, category: .appearance, triage: .consequential, basis: .observed, subjectKey: read.subject, claim: read.claim, evidence: read.evidence,
      proposed: proposed, flag: nil, dependents: nil, decision: nil, edited: nil, reason: nil, autoKept: false)
    let carried = resolveReviewChain([
      RevisionReview(
        revision: record.draftRevision, items: [reviewItem],
        answers: answers.map { FinalizeAnswer(itemKey: $0.item, decision: .kept, proposalDigest: $0.answer.proposalDigest) })
    ])
    #expect(carried.first?.decision == .kept)
  }

  @Test func shouldAddressAFindingWhoseIdArrivedDecomposedByItsRemedy() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A8)
    let record = Gen.chapterReview(&generator, novel: novel)
    var item = record.item
    item["findings"] = [["id": "Ame\u{301}lie", "severity": "warning", "category": "continuity", "text": "t", "evidence": nil, "fingerprint": "fp"]]
    try await appendRaw(record.ref, item, in: store)
    let finding = try #require(try await readAppended(record.ref, as: ChapterReviewRecord.self, in: store).entry?.record.findings.first)
    #expect(finding.id == "Am\u{E9}lie")
    _ = try await store.write { transaction in
      try ReviewRemedyRecord.set(novel: novel, review: record.id, finding: "Ame\u{301}lie", remedy(.dismissed), in: &transaction)
    }
    let remedied = try await store.read { transaction in try ReviewRemedyRecord.listing(novel: novel, in: transaction) }.live
    #expect(remedied.map(\.finding) == [finding.id])
    #expect(remedied.first?.finding.utf8.elementsEqual(finding.id.utf8) == true)
  }

  @Test func shouldIdentifyAFinalizeReviewByItsAttemptAndReadAnotherAttemptAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A2)
    let record = Gen.finalizeReview(&generator, novel: novel)
    #expect(record.id == record.attempt.uuid)
    #expect(FinalizeReviewRecord.ref(attempt: record.attempt) == record.ref)
    let foreign = Gen.attempt(&generator)
    var item = record.item
    item["attempt"] = foreign.json
    try await appendRaw(record.ref, item, in: store)
    #expect(try await readAppended(record.ref, as: FinalizeReviewRecord.self, in: store) == .unreadable(.invalid(field: "attempt")))
    var notSeven = Gen.finalizeReview(&generator, novel: novel).item
    let plain = generator.uuid()
    notSeven["attempt"] = plain.json
    try await appendRaw(FinalizeReviewRecord.ref(plain), notSeven, in: store)
    #expect(try await readAppended(FinalizeReviewRecord.ref(plain), as: FinalizeReviewRecord.self, in: store) == .unreadable(.invalid(field: "attempt")))
  }

  @Test func shouldKeepNewerMembersOfFindingsItemsAndTheirRecords() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A3)
    let reviewRecord = Gen.chapterReview(&generator, novel: novel)
    var item = reviewRecord.item
    item["findings"] = [["id": "f1", "severity": "x_fatal", "category": "continuity", "text": "t", "evidence": nil, "fingerprint": "fp", "span": [3, 9]]]
    item["metrics"] = ["readability": 61]
    try await appendRaw(reviewRecord.ref, item, in: store)
    let readReview = try #require(try await readAppended(reviewRecord.ref, as: ChapterReviewRecord.self, in: store).entry?.record)
    #expect(readReview.findings.first?.severity == .unknown("x_fatal"))
    #expect(readReview.findings.first?.unrecognised == ["span": [3, 9]])
    #expect(readReview.unrecognised == ["metrics": ["readability": 61]])
    #expect(readReview.item == item)

    let finalizeReview = Gen.finalizeReview(&generator, novel: novel)
    item = finalizeReview.item
    let proposed: JSONValue = ["category": "entity", "entity": ["entityKey": "aria", "name": "Aria", "type": "character"]]
    item["items"] = [
      [
        "key": "entity:aria", "position": 0, "category": "entity", "triage": "routine", "basis": "x_guessed", "subject": "aria", "claim": "c", "evidence": nil,
        "proposed": proposed, "flag": nil, "dependents": nil, "auto_decision": "kept", "decided_at": 5,
      ]
    ]
    item["bridge_only"] = false
    try await appendRaw(finalizeReview.ref, item, in: store)
    let readFinalize = try #require(try await readAppended(finalizeReview.ref, as: FinalizeReviewRecord.self, in: store).entry?.record)
    #expect(readFinalize.items.first?.basis == .unknown("x_guessed"))
    #expect(readFinalize.items.first?.autoDecision == .known(.kept))
    #expect(readFinalize.items.first?.proposed == proposed.objectValue)
    #expect(readFinalize.items.first?.unrecognised == ["decided_at": 5])
    #expect(readFinalize.item == item)
  }

  @Test(arguments: [JSONValue.string("entity"), ["category": "entity"] as JSONValue])
  func shouldReadAFinalizeItemWhoseProposedChangeIsNotAnObjectAsUnreadable(_ proposed: JSONValue) async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A4)
    let record = Gen.finalizeReview(&generator, novel: novel)
    var stored = Gen.finalizeItem(&generator, key: "entity:aria", position: 0).json.objectValue ?? [:]
    stored["proposed"] = proposed
    var item = record.item
    item["items"] = [.object(stored)]
    try await appendRaw(record.ref, item, in: store)
    let reading = try await readAppended(record.ref, as: FinalizeReviewRecord.self, in: store)
    if proposed.objectValue == nil {
      #expect(reading == .unreadable(.invalid(field: "items")))
    } else {
      #expect(reading.entry?.record.items.first?.proposed == proposed.objectValue)
    }
  }

  @Test func shouldListTheReviewsAndReportsOfOneChapterOnly() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A5)
    let three = [Gen.chapterReview(&generator, novel: novel, chapter: 3), Gen.chapterReview(&generator, novel: novel, chapter: 3)]
    let elsewhere = [Gen.chapterReview(&generator, novel: novel, chapter: 4), Gen.chapterReview(&generator, novel: other, chapter: 3)]
    for record in three + elsewhere { _ = try await store.write { transaction in try record.append(in: &transaction) } }
    let finalize = Gen.finalizeReview(&generator, novel: novel, chapter: 3)
    let report = Gen.refreshReport(&generator, novel: novel, chapter: 3)
    _ = try await store.write { transaction in
      _ = try finalize.append(in: &transaction)
      return try report.append(in: &transaction)
    }
    let listed = try await store.read { transaction in
      (
        reviews: try ChapterReviewRecord.listing(novel: novel, chapter: 3, in: transaction), finalize: try FinalizeReviewRecord.listing(novel: novel, chapter: 3, in: transaction),
        reports: try RefreshReportRecord.listing(novel: novel, chapter: 4, in: transaction)
      )
    }
    #expect(Set(listed.reviews.records.map(\.id)) == Set(three.map(\.id)))
    #expect(listed.finalize.records == [finalize])
    #expect(listed.reports.records.isEmpty)
  }

  @Test func shouldTakeNoLaterFieldsOnAnAppendedReviewOrReport() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x6A6)
    let refs = [Gen.chapterReview(&generator, novel: novel).ref, Gen.finalizeReview(&generator, novel: novel).ref, Gen.refreshReport(&generator, novel: novel).ref]
    for (ref, item) in zip(
      refs, [Gen.chapterReview(&generator, novel: novel).item, Gen.finalizeReview(&generator, novel: novel).item, Gen.refreshReport(&generator, novel: novel).item])
    {
      try await appendRaw(ref, item, in: store)
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["disposition": "clear"], in: store) }
      await #expect(throws: StoreError.self) { try await appendRaw(ref, item, in: store) }
    }
  }

  @Test func shouldSetAndClearARemedyThroughTheKeyAndRefuseAnEdit() async throws {
    let store = try SchemaFixture.store()
    let set = try await store.write { transaction in
      try ReviewRemedyRecord.set(novel: novel, review: review, finding: "e\u{301}", remedy(.dismissed, reason: "intended"), in: &transaction)
    }
    #expect(Set(set.fields.keys) == ["natural_key", "remedy"])
    let ref = ReviewRemedyRecord.ref(novel: novel, review: review, finding: "\u{E9}")
    #expect(set.key == ref.key)
    let stored = ReviewRemedyRecord(novel: novel, review: review, finding: "\u{E9}", remedy: remedy(.dismissed, reason: "intended"))
    #expect(try await Harness.read(ref, as: ReviewRemedyRecord.self, in: store) == .readable(RecordEntry(record: stored, isRemoved: false)))
    let cleared = try await store.write { transaction in try ReviewRemedyRecord.clear(novel: novel, review: review, finding: "\u{E9}", in: &transaction) }
    #expect(cleared.fields["remedy"] == .null)
    #expect(try await store.read { transaction in try ReviewRemedyRecord.read(novel: novel, review: review, finding: "\u{E9}", in: transaction) }.entry?.record.remedy == nil)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try ReviewRemedyRecord.edit(ref, stored.fields, in: &transaction) }
    }
  }

  @Test func shouldReadARemedyTotallyAndKeepItsNewerMembers() async throws {
    let store = try SchemaFixture.store()
    let key = NovelForgeKey.reviewRemedyKey(novel: novel, review: review, finding: "f1")
    try await SchemaFixture.set(key.ref, ["remedy": ["action": "dismissed", "fingerprint": "fp"]], in: store)
    #expect(try await Harness.read(key.ref, as: ReviewRemedyRecord.self, in: store) == .absent)
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "remedy": ["action": "x_deferred", "fingerprint": "fp", "reason": nil, "until": 9]], in: store)
    let read = try #require(try await Harness.read(key.ref, as: ReviewRemedyRecord.self, in: store).entry?.record)
    #expect(read.remedy?.action == .unknown("x_deferred"))
    #expect(read.remedy?.json == ["action": "x_deferred", "fingerprint": "fp", "reason": nil, "until": 9])
    for malformed: JSONValue in [["action": "dismissed"], ["fingerprint": "fp"], "dismissed", ["action": 1, "fingerprint": "fp"]] {
      try await SchemaFixture.set(key.ref, ["remedy": malformed], in: store)
      #expect(try await Harness.read(key.ref, as: ReviewRemedyRecord.self, in: store) == .unreadable(.invalid(field: "remedy")))
    }
  }

  @Test func shouldLetTheLaterOfASetAndAClearStandOnEveryReplica() async throws {
    try await forAll(iterations: 6, seed: 0x6B1) { generator in
      let replicas = try await replicas(seed: generator.next())
      let finding = Gen.key(&generator)
      let clearsLast = generator.chance(0.5)
      let ref = ReviewRemedyRecord.ref(novel: novel, review: review, finding: finding)
      let first = remedy(.fixingMyself)
      _ = try await replicas.write(0) { transaction in try ReviewRemedyRecord.set(novel: novel, review: review, finding: finding, first, in: &transaction) }
      await replicas.advanceClock(of: 1, by: .seconds(5))
      let second = remedy(.overridden, reason: "the author's call")
      _ = try await replicas.write(1) { transaction in
        clearsLast
          ? try ReviewRemedyRecord.clear(novel: novel, review: review, finding: finding, in: &transaction)
          : try ReviewRemedyRecord.set(novel: novel, review: review, finding: finding, second, in: &transaction)
      }
      try await replicas.settle()
      let expected = ReviewRemedyRecord(novel: novel, review: review, finding: finding, remedy: clearsLast ? nil : second)
      try await expectAgreement(ref, as: ReviewRemedyRecord.self, in: replicas, is: live(expected))
    }
  }

  @Test func shouldDecideAnItemByItsChapterRevisionAndKeyAndRefuseAnEdit() async throws {
    let store = try SchemaFixture.store()
    let kept = try decision(item: "entity:Ame\u{301}lie", answer(.edited, digest: "d1", edit: ["category": "entity", "entity": ["entityKey": "amelie", "name": "Amy"]]))
    #expect(kept.item == "entity:Am\u{E9}lie")
    #expect(kept.ref == (try FinalizeDecisionRecord.ref(novel: novel, chapter: 3, draftRevision: revision, item: "entity:Am\u{E9}lie")))
    let change = try await Harness.create(kept, in: store)
    #expect(Set(change.fields.keys) == ["natural_key", "decision"])
    #expect(try await Harness.read(kept.ref, as: FinalizeDecisionRecord.self, in: store) == .readable(RecordEntry(record: kept, isRemoved: false)))
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(0)) { try decision(chapter: 0, answer(.kept, digest: "d")) }
    let ref = kept.ref
    await #expect(throws: StoreError.self) { try await store.write { transaction in try FinalizeDecisionRecord.edit(ref, kept.fields, in: &transaction) } }
  }

  @Test func shouldReadADecisionTotallyAndKeepItsNewerMembers() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey.finalizeDecisionKey(novel: novel, chapter: 3, draftRevision: revision, item: "summary")
    try await SchemaFixture.set(key.ref, ["decision": ["decision": "kept", "proposal_digest": "d", "auto": true]], in: store)
    #expect(try await Harness.read(key.ref, as: FinalizeDecisionRecord.self, in: store) == .absent)
    let newer: JSONValue = ["decision": "x_deferred", "proposal_digest": "d", "edit": nil, "reason": nil, "auto": false, "decided_at": 4]
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "decision": newer], in: store)
    let read = try #require(try await Harness.read(key.ref, as: FinalizeDecisionRecord.self, in: store).entry?.record)
    #expect(read.answer.decision == .unknown("x_deferred"))
    #expect(read.answer.json == newer)
    for malformed: JSONValue in [
      ["decision": "kept", "auto": false], ["proposal_digest": "d", "auto": false], ["decision": "kept", "proposal_digest": "d"],
      ["decision": "edited", "proposal_digest": "d", "auto": false, "edit": "name"], .null,
    ] {
      try await SchemaFixture.set(key.ref, ["decision": malformed], in: store)
      let reading = try await Harness.read(key.ref, as: FinalizeDecisionRecord.self, in: store)
      #expect(reading == .unreadable(.invalid(field: "decision")), "\(malformed)")
    }
  }

  @Test func shouldListEveryRevisionsAnswersOfOneChapterAndCountUnreadableOnesOfIt() async throws {
    let store = try SchemaFixture.store()
    let mine = [try decision(draftRevision: "v:one", answer(.kept, digest: "a")), try decision(draftRevision: "v:two", item: "summary", answer(.skipped, digest: "b"))]
    let theirs = [try decision(chapter: 4, answer(.kept, digest: "c")), try decision(answer(.kept, digest: "d"), novel: other)]
    for record in mine + theirs { _ = try await Harness.create(record, in: store) }
    let broken = try NovelForgeKey.finalizeDecisionKey(novel: novel, chapter: 3, draftRevision: "v:three", item: "summary")
    try await SchemaFixture.set(broken.ref, ["natural_key": broken.stored, "decision": "kept"], in: store)
    let elsewhere = try NovelForgeKey.finalizeDecisionKey(novel: novel, chapter: 5, draftRevision: "v:three", item: "summary")
    try await SchemaFixture.set(elsewhere.ref, ["natural_key": elsewhere.stored, "decision": "kept"], in: store)
    let listing = try await store.read { transaction in try FinalizeDecisionRecord.listing(novel: novel, chapter: 3, in: transaction) }
    #expect(Set(listing.live.map(\.ref)) == Set(mine.map(\.ref)))
    #expect(listing.unreadable == 1)
  }

  @Test func shouldTakeTheLaterAnswerWholeOnEveryReplica() async throws {
    try await forAll(iterations: 6, seed: 0x6B2) { generator in
      let replicas = try await replicas(seed: generator.next())
      let item = "entity:" + Gen.key(&generator)
      let earlier = answer(.edited, digest: "d1", reason: "a better name", edit: ["category": "entity"])
      let later = answer(.skipped, digest: "d2")
      let laterOn = generator.int(in: 0...2)
      let earlierOn = (laterOn + 1) % 3
      let (first, second) = (try decision(item: item, earlier), try decision(item: item, later))
      _ = try await replicas.write(earlierOn) { transaction in try first.create(in: &transaction) }
      await replicas.advanceClock(of: laterOn, by: .seconds(5))
      _ = try await replicas.write(laterOn) { transaction in try second.create(in: &transaction) }
      try await replicas.settle()
      try await expectAgreement(first.ref, as: FinalizeDecisionRecord.self, in: replicas, is: live(second))
    }
  }
}

import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel
private let wrong = JSONValue.array([.null])

extension Gen {
  static func approval(_ generator: inout SeededGenerator, novel: UUID, chapter: Int? = nil) -> ApprovalRecord {
    ApprovalRecord(
      id: generator.uuid(), novel: novel, chapter: chapter ?? generator.int(in: 1...40), approvalKind: stored(&generator), draftRevision: revision(&generator),
      planRevision: revision(&generator), planTermsDigest: optionalText(&generator), upstreamDigest: optionalText(&generator))
  }

  static func notebookEntry(_ generator: inout SeededGenerator, novel: UUID) -> NotebookEntryRecord {
    let links = NotebookLinks(
      pages: generator.chance(0.5) ? nil : [NotebookPageLink(section: .known(.world), slug: text(&generator)), NotebookPageLink(section: .unknown("x_atlas"), slug: "a")],
      entities: optionalTexts(&generator), facts: optionalTexts(&generator), volumes: optionalTexts(&generator), chapters: generator.chance(0.5) ? nil : [1, 3])
    return NotebookEntryRecord(
      id: generator.uuid(), novel: novel, entryKind: stored(&generator), topic: text(&generator), statement: text(&generator), why: optionalText(&generator),
      rejectedAlternatives: texts(&generator), writerLine: optionalText(&generator), decidedBy: stored(&generator), stepKey: optionalText(&generator),
      payload: optionalJSON(&generator), links: links, supersedes: generator.chance(0.5) ? nil : generator.uuid(), idea: optionalText(&generator),
      rejectionScope: optionalStored(&generator), rejectionAnchor: optionalJSON(&generator))
  }

  static func withdrawal(_ generator: inout SeededGenerator, novel: UUID, entry: UUID? = nil) -> NotebookWithdrawalRecord {
    NotebookWithdrawalRecord(id: generator.uuid(), novel: novel, entry: entry ?? generator.uuid(), reason: text(&generator))
  }

  static func attempt(_ generator: inout SeededGenerator) -> AttemptID {
    do {
      return try AttemptID(UUID.v7(at: Date(timeIntervalSince1970: 1_800_000_000), using: &generator))
    } catch {
      preconditionFailure("UUID.v7 makes a version 7 UUID")
    }
  }

  static func jobKey(_ generator: inout SeededGenerator) -> EntityKey { EntityKey(uuid: generator.uuid()) }

  static func object(_ generator: inout SeededGenerator) -> [String: JSONValue] {
    ["category": .string(text(&generator)), "entityKey": .string(text(&generator)), "nested": [.int(Int64(int(&generator))), .null]]
  }

  static func finding(_ generator: inout SeededGenerator, id: String) -> ReviewFinding {
    ReviewFinding(
      id: id, severity: stored(&generator), category: stored(&generator), text: text(&generator), evidence: optionalText(&generator), fingerprint: revision(&generator))
  }

  static func chapterReview(_ generator: inout SeededGenerator, novel: UUID, chapter: Int? = nil) -> ChapterReviewRecord {
    let findings = (0..<generator.int(in: 0...3)).map { index in finding(&generator, id: "f\(index)") }
    do {
      return try ChapterReviewRecord(
        id: generator.uuid(), novel: novel, chapter: chapter ?? generator.int(in: 1...40), reviewKind: stored(&generator), draftRevision: optionalText(&generator),
        bodyHash: revision(&generator), disposition: stored(&generator), verdict: optionalText(&generator), findings: findings, isolated: bool(&generator),
        note: optionalText(&generator), checked: texts(&generator), generationPass: bool(&generator), job: generator.chance(0.5) ? nil : jobKey(&generator),
        attempt: generator.chance(0.5) ? nil : attempt(&generator), calls: generator.chance(0.5) ? nil : [generator.uuid(), generator.uuid()])
    } catch {
      preconditionFailure("the finding ids are distinct")
    }
  }

  static func finalizeItem(_ generator: inout SeededGenerator, key: String, position: Int) -> StoredFinalizeItem {
    StoredFinalizeItem(
      key: key, position: position, category: stored(&generator), triage: stored(&generator), basis: stored(&generator), subject: text(&generator), claim: text(&generator),
      evidence: optionalText(&generator), proposed: object(&generator), flag: optionalStored(&generator), dependents: optionalTexts(&generator),
      autoDecision: optionalStored(&generator))
  }

  static func finalizeReview(_ generator: inout SeededGenerator, novel: UUID, chapter: Int? = nil) -> FinalizeReviewRecord {
    let items = (0..<generator.int(in: 0...3)).map { position in finalizeItem(&generator, key: "entity:e\(position)", position: position) }
    do {
      return try FinalizeReviewRecord(
        attempt: attempt(&generator), job: jobKey(&generator), novel: novel, chapter: chapter ?? generator.int(in: 1...40), draftRevision: revision(&generator),
        sourceHash: revision(&generator), planHash: optionalText(&generator), isolated: bool(&generator), items: items)
    } catch {
      preconditionFailure("the item keys are distinct")
    }
  }

  static func refreshReport(_ generator: inout SeededGenerator, novel: UUID, chapter: Int? = nil) -> RefreshReportRecord {
    RefreshReportRecord(
      id: generator.uuid(), novel: novel, chapter: chapter ?? generator.int(in: 1...40), canonDigest: revision(&generator),
      findings: (0..<generator.int(in: 0...2)).map { _ in object(&generator) }, checked: object(&generator), copy: text(&generator),
      proposal: generator.chance(0.5) ? nil : generator.uuid(), attempt: generator.chance(0.5) ? nil : attempt(&generator))
  }
}

private func append<R: AppendedRecord>(_ record: R, in store: VaultStore) async throws -> ChangeRecord {
  try await store.write { transaction in try record.append(in: &transaction) }
}

private func appendRaw(_ ref: EntityRef, _ item: [String: JSONValue], in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.append(ref, item: item) }
}

private func read<R: AppendedRecord>(_ ref: EntityRef, as _: R.Type, in store: VaultStore) async throws -> AppendedReading<R> {
  try await store.read { transaction in try R.read(ref, in: transaction) }
}

private func appendedRoundTrip<R: AppendedRecord>(_ make: (inout SeededGenerator, UUID) -> R, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: 40, seed: seed) { generator in
    let record = make(&generator, generator.uuid())
    #expect(record.ref == R.ref(record.id))
    #expect(try await read(record.ref, as: R.self, in: store) == .absent)
    let change = try await append(record, in: store)
    #expect(Set(change.fields.keys) == Set(R.Member.allCases.map(\.rawValue)))
    #expect(try await read(record.ref, as: R.self, in: store) == .readable(AppendedEntry(record: record, clock: change.clock)))
    #expect(try await store.read { transaction in try R.read(id: record.id, in: transaction) }.entry?.record == record)
    await #expect(throws: StoreError.self) { try await append(record, in: store) }
  }
}

private func appendedTotality<R: AppendedRecord>(_ make: (inout SeededGenerator, UUID) -> R, required: Set<String>, anyJSON: Set<String> = [], seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  try await forAll(iterations: 3, seed: seed) { generator in
    let names = make(&generator, novel).item.keys.sorted()
    for name in names {
      let missing = make(&generator, novel)
      var item = missing.item
      item[name] = nil
      try await appendRaw(missing.ref, item, in: store)
      let afterRemoval = try await read(missing.ref, as: R.self, in: store)
      if required.contains(name) {
        #expect(afterRemoval == .unreadable(.missing(field: name)), "missing \(name)")
      } else {
        #expect(afterRemoval.entry?.record.item[name] == JSONValue.null, "missing \(name)")
      }
      let corrupt = make(&generator, novel)
      item = corrupt.item
      item[name] = wrong
      try await appendRaw(corrupt.ref, item, in: store)
      let afterCorruption = try await read(corrupt.ref, as: R.self, in: store)
      if anyJSON.contains(name) {
        #expect(afterCorruption.entry?.record.item[name] == wrong, "\(name) carries any JSON")
      } else {
        #expect(afterCorruption == .unreadable(.invalid(field: name)), "wrong type \(name)")
      }
    }
    let newer = make(&generator, novel)
    var item = newer.item
    item[Harness.newerMember] = ["nested": [1, 2]]
    try await appendRaw(newer.ref, item, in: store)
    let carried = try #require(try await read(newer.ref, as: R.self, in: store).entry?.record)
    #expect(carried.item == item)
    #expect(carried.unrecognised == [Harness.newerMember: ["nested": [1, 2]]])

    let uppercase = make(&generator, novel)
    item = uppercase.item
    item["novel"] = .string(novel.uuidString.uppercased())
    try await appendRaw(uppercase.ref, item, in: store)
    #expect(try await read(uppercase.ref, as: R.self, in: store) == .unreadable(.invalid(field: "novel")))
  }

  var seeding = SeededGenerator(seed: seed)
  let record = make(&seeding, novel)
  let notUUID = EntityRef(kind: R.kind.entityKind, key: EntityKey("not-a-uuid") ?? record.ref.key)
  try await appendRaw(notUUID, record.item, in: store)
  #expect(try await read(notUUID, as: R.self, in: store) == .unreadable(.identity(notUUID)))
  let volume = VolumeRecord(novel: novel, volume: "v", ordinal: 1)
  _ = try await Harness.create(volume, in: store)
  #expect(try await read(volume.ref, as: R.self, in: store) == .unreadable(.identity(volume.ref)))
}

private func appendedListing<R: AppendedRecord>(_ make: (inout SeededGenerator, UUID) -> R, seed: UInt64) async throws {
  let store = try SchemaFixture.store()
  var generator = SeededGenerator(seed: seed)
  var mine = [AppendedEntry<R>]()
  for _ in 0..<4 {
    let record = make(&generator, novel)
    mine.append(AppendedEntry(record: record, clock: try await append(record, in: store).clock))
  }
  var theirs = [R]()
  for _ in 0..<2 {
    let record = make(&generator, other)
    _ = try await append(record, in: store)
    theirs.append(record)
  }
  let broken = make(&generator, novel)
  var item = broken.item
  item[R.Member.allCases.map(\.rawValue).first { $0 != "novel" } ?? "novel"] = wrong
  try await appendRaw(broken.ref, item, in: store)
  let orphan = make(&generator, other)
  item = orphan.item
  item["novel"] = nil
  try await appendRaw(orphan.ref, item, in: store)

  let listing = try await store.read { transaction in try R.listing(novel: novel, in: transaction) }
  #expect(listing == AppendedListing(entries: mine, unreadable: 1, unattributed: 0))
  let theirListing = try await store.read { transaction in try R.listing(novel: other, in: transaction) }
  #expect(theirListing.records.map(\.id) == theirs.map(\.id))
  #expect(theirListing.unreadable == 0)
  let all = try await store.read { transaction in try R.listing(in: transaction) }
  #expect(all.entries.count == 6)
  #expect(all.unreadable == 1)
  #expect(all.unattributed == 1)
  #expect(all.entries.map(\.clock) == all.entries.map(\.clock).sorted())
}

private func appendedConvergence<R: AppendedRecord>(_ make: @escaping @Sendable (inout SeededGenerator, UUID) -> R, seed: UInt64) async throws {
  try await forAll(iterations: 10, seed: seed) { generator in
    let replicas = try await replicas(seed: generator.next())
    let id = generator.uuid()
    var written = Set<UUID>()
    for _ in 0..<10 {
      let index = generator.int(in: 0...(replicas.count - 1))
      switch generator.int(in: 0...9) {
      case 0..<5:
        let record = make(&generator, id)
        written.insert(record.id)
        _ = try await replicas.write(index) { transaction in try record.append(in: &transaction) }
      case 5..<7:
        await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3)))
      default:
        _ = try await replicas.step(using: &generator)
      }
    }
    try await replicas.settle()
    var listings = [AppendedListing<R>]()
    for index in 0..<replicas.count { listings.append(try await replicas.store(index).read { transaction in try R.listing(novel: id, in: transaction) }) }
    for listing in listings.dropFirst() { #expect(listing == listings[0]) }
    #expect(Set(listings[0].records.map(\.id)) == written)
  }
}

@Suite("Appended records", TestTimeLimit.standard)
struct AppendedRecordTests {
  @Test func shouldAppendAndReadAnApproval() async throws { try await appendedRoundTrip({ Gen.approval(&$0, novel: $1) }, seed: 0x3A1) }
  @Test func shouldAppendAndReadANotebookEntry() async throws { try await appendedRoundTrip({ Gen.notebookEntry(&$0, novel: $1) }, seed: 0x3A2) }
  @Test func shouldAppendAndReadANotebookWithdrawal() async throws { try await appendedRoundTrip({ Gen.withdrawal(&$0, novel: $1) }, seed: 0x3A3) }
  @Test func shouldAppendAndReadAChapterReview() async throws { try await appendedRoundTrip({ Gen.chapterReview(&$0, novel: $1) }, seed: 0x3A4) }
  @Test func shouldAppendAndReadAFinalizeReview() async throws { try await appendedRoundTrip({ Gen.finalizeReview(&$0, novel: $1) }, seed: 0x3A5) }
  @Test func shouldAppendAndReadARefreshReport() async throws { try await appendedRoundTrip({ Gen.refreshReport(&$0, novel: $1) }, seed: 0x3A6) }

  @Test func shouldReadAnApprovalTotally() async throws {
    try await appendedTotality(
      { Gen.approval(&$0, novel: $1) }, required: ["novel", "chapter", "kind", "draft_revision", "plan_revision"], seed: 0x3B1)
  }
  @Test func shouldReadANotebookEntryTotally() async throws {
    try await appendedTotality(
      { Gen.notebookEntry(&$0, novel: $1) }, required: ["novel", "kind", "topic", "statement", "rejected_alternatives", "decided_by", "links"],
      anyJSON: ["payload", "rejection_anchor"], seed: 0x3B2)
  }
  @Test func shouldReadANotebookWithdrawalTotally() async throws {
    try await appendedTotality({ Gen.withdrawal(&$0, novel: $1) }, required: ["novel", "entry", "reason"], seed: 0x3B3)
  }
  @Test func shouldReadAChapterReviewTotally() async throws {
    try await appendedTotality(
      { Gen.chapterReview(&$0, novel: $1) }, required: ["novel", "chapter", "kind", "body_hash", "disposition", "findings", "isolated", "checked", "generation_pass"],
      seed: 0x3B4)
  }
  @Test func shouldReadAFinalizeReviewTotally() async throws {
    try await appendedTotality(
      { Gen.finalizeReview(&$0, novel: $1) }, required: ["novel", "chapter", "draft_revision", "source_hash", "isolated", "job", "attempt", "items"], seed: 0x3B5)
  }
  @Test func shouldReadARefreshReportTotally() async throws {
    try await appendedTotality(
      { Gen.refreshReport(&$0, novel: $1) }, required: ["novel", "chapter", "canon_digest", "findings", "checked", "copy"], seed: 0x3B6)
  }

  @Test func shouldListOnlyTheApprovalsOfTheNovel() async throws { try await appendedListing({ Gen.approval(&$0, novel: $1) }, seed: 0x3C1) }
  @Test func shouldListOnlyTheNotebookEntriesOfTheNovel() async throws { try await appendedListing({ Gen.notebookEntry(&$0, novel: $1) }, seed: 0x3C2) }
  @Test func shouldListOnlyTheNotebookWithdrawalsOfTheNovel() async throws { try await appendedListing({ Gen.withdrawal(&$0, novel: $1) }, seed: 0x3C3) }
  @Test func shouldListOnlyTheChapterReviewsOfTheNovel() async throws { try await appendedListing({ Gen.chapterReview(&$0, novel: $1) }, seed: 0x3C4) }
  @Test func shouldListOnlyTheFinalizeReviewsOfTheNovel() async throws { try await appendedListing({ Gen.finalizeReview(&$0, novel: $1) }, seed: 0x3C5) }
  @Test func shouldListOnlyTheRefreshReportsOfTheNovel() async throws { try await appendedListing({ Gen.refreshReport(&$0, novel: $1) }, seed: 0x3C6) }

  @Test func shouldSettleApprovalsToTheSameListingOnEveryReplica() async throws { try await appendedConvergence({ Gen.approval(&$0, novel: $1) }, seed: 0x3D1) }
  @Test func shouldSettleNotebookEntriesToTheSameListingOnEveryReplica() async throws {
    try await appendedConvergence({ Gen.notebookEntry(&$0, novel: $1) }, seed: 0x3D2)
  }
  @Test func shouldSettleNotebookWithdrawalsToTheSameListingOnEveryReplica() async throws {
    try await appendedConvergence({ Gen.withdrawal(&$0, novel: $1) }, seed: 0x3D3)
  }
  @Test func shouldSettleChapterReviewsToTheSameListingOnEveryReplica() async throws { try await appendedConvergence({ Gen.chapterReview(&$0, novel: $1) }, seed: 0x3D4) }
  @Test func shouldSettleFinalizeReviewsToTheSameListingOnEveryReplica() async throws { try await appendedConvergence({ Gen.finalizeReview(&$0, novel: $1) }, seed: 0x3D5) }
  @Test func shouldSettleRefreshReportsToTheSameListingOnEveryReplica() async throws { try await appendedConvergence({ Gen.refreshReport(&$0, novel: $1) }, seed: 0x3D6) }

  @Test func shouldWriteEveryMemberOfAnAppendedItemAndOfNotebookLinks() throws {
    let approval = ApprovalRecord(novel: novel, chapter: 1, draftRevision: "v:d", planRevision: "v:p")
    #expect(Set(approval.item.keys) == Set(ApprovalMember.allCases.map(\.rawValue)))
    let entry = NotebookEntryRecord(novel: novel, entryKind: .known(.decision), topic: "t", statement: "s")
    #expect(Set(entry.item.keys) == Set(NotebookEntryMember.allCases.map(\.rawValue)))
    #expect(Set(try #require(entry.links.json.objectValue).keys) == Set(NotebookLinksMember.allCases.map(\.rawValue)))
    let withdrawal = NotebookWithdrawalRecord(novel: novel, entry: entry.id, reason: "r")
    #expect(Set(withdrawal.item.keys) == Set(NotebookWithdrawalMember.allCases.map(\.rawValue)))
  }

  @Test func shouldReadHandWrittenAppendedItemsFromTheMemberNames() async throws {
    let store = try SchemaFixture.store()
    let id = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000a1")
    let lowerNovel = JSONValue.string(novel.uuidString.lowercased())
    try await appendRaw(
      ApprovalRecord.ref(id),
      [
        "novel": lowerNovel, "chapter": 3, "kind": "as_written", "draft_revision": "v:d", "plan_revision": "v:p", "plan_terms_digest": "terms",
        "upstream_digest": nil,
      ], in: store)
    let approval = ApprovalRecord(id: id, novel: novel, chapter: 3, approvalKind: .known(.asWritten), draftRevision: "v:d", planRevision: "v:p", planTermsDigest: "terms")
    #expect(try await read(ApprovalRecord.ref(id), as: ApprovalRecord.self, in: store).entry?.record == approval)

    try await appendRaw(
      NotebookEntryRecord.ref(id),
      [
        "novel": lowerNovel, "kind": "rejected", "topic": "ending", "statement": "No twin", "why": nil, "rejected_alternatives": ["twin"], "writer_line": nil,
        "decided_by": "author", "step_key": nil, "payload": ["x": 1], "links": ["pages": [["section": "world", "slug": "harbour"]], "chapters": [2]],
        "supersedes": nil, "idea": "idea-1", "rejection_scope": "not_now", "rejection_anchor": ["volumeKey": nil],
      ], in: store)
    let entry = NotebookEntryRecord(
      id: id, novel: novel, entryKind: .known(.rejected), topic: "ending", statement: "No twin", rejectedAlternatives: ["twin"], payload: ["x": 1],
      links: NotebookLinks(pages: [NotebookPageLink(section: .known(.world), slug: "harbour")], chapters: [2]), idea: "idea-1", rejectionScope: .known(.notNow),
      rejectionAnchor: ["volumeKey": nil])
    #expect(try await read(NotebookEntryRecord.ref(id), as: NotebookEntryRecord.self, in: store).entry?.record == entry)

    try await appendRaw(NotebookWithdrawalRecord.ref(id), ["novel": lowerNovel, "entry": .string(id.uuidString.lowercased()), "reason": "changed my mind"], in: store)
    let withdrawal = NotebookWithdrawalRecord(id: id, novel: novel, entry: id, reason: "changed my mind")
    #expect(try await read(NotebookWithdrawalRecord.ref(id), as: NotebookWithdrawalRecord.self, in: store).entry?.record == withdrawal)
  }

  @Test(arguments: [JSONValue.object(["pages": [["section": "world"]]]), ["chapters": ["2"]], ["entities": "aria"], "links"])
  func shouldReadANotebookEntryWithMalformedLinksAsUnreadable(_ links: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let entry = NotebookEntryRecord(novel: novel, entryKind: .known(.decision), topic: "t", statement: "s")
    var item = entry.item
    item["links"] = links
    try await appendRaw(entry.ref, item, in: store)
    #expect(try await read(entry.ref, as: NotebookEntryRecord.self, in: store) == .unreadable(.invalid(field: "links")))
  }

  @Test func shouldKeepNewerMembersOfNotebookLinks() async throws {
    let store = try SchemaFixture.store()
    let entry = NotebookEntryRecord(novel: novel, entryKind: .known(.decision), topic: "t", statement: "s")
    var item = entry.item
    item["links"] = ["facts": ["heir"], "threads": ["locket"]]
    try await appendRaw(entry.ref, item, in: store)
    let read = try #require(try await read(entry.ref, as: NotebookEntryRecord.self, in: store).entry?.record)
    #expect(read.links.facts == ["heir"])
    #expect(read.links.unrecognised == ["threads": ["locket"]])
    #expect(read.item["links"] == ["facts": ["heir"], "threads": ["locket"], "pages": nil, "entities": nil, "volumes": nil, "chapters": nil])
  }

  @Test func shouldListTheApprovalsOfOneChapterAndCountUnreadableOnesThatMayBelongToIt() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0x3E1)
    let three = [Gen.approval(&generator, novel: novel, chapter: 3), Gen.approval(&generator, novel: novel, chapter: 3)]
    let four = Gen.approval(&generator, novel: novel, chapter: 4)
    let elsewhere = Gen.approval(&generator, novel: other, chapter: 3)
    for record in three + [four, elsewhere] { _ = try await append(record, in: store) }
    for (chapter, member) in [(JSONValue.int(3), "draft_revision"), (.int(4), "draft_revision"), (wrong, "chapter")] {
      let broken = Gen.approval(&generator, novel: novel)
      var item = broken.item
      item["chapter"] = chapter
      item[member] = wrong
      try await appendRaw(broken.ref, item, in: store)
    }
    let listing = try await store.read { transaction in try ApprovalRecord.listing(novel: novel, chapter: 3, in: transaction) }
    #expect(Set(listing.records.map(\.id)) == Set(three.map(\.id)))
    #expect(listing.unreadable == 2)
  }
}

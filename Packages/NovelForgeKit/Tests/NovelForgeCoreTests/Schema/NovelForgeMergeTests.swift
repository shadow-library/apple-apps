import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@Suite("NovelForge merge", TestTimeLimit.standard)
struct NovelForgeMergeTests {
  private static let novel = SchemaFixture.novel

  private static func keyed(_ components: NovelForgeKey.Components) throws -> (ref: EntityRef, key: JSONValue) {
    let key = try NovelForgeKey(novel: novel, components)
    return (key.ref, key.stored)
  }

  private static func agreedRecord(_ ref: EntityRef, _ devices: Devices) async throws -> RecordState {
    let record = try await SchemaFixture.record(ref, in: devices.first)
    #expect(record == (try await SchemaFixture.record(ref, in: devices.second)))
    return record
  }

  private static func agreedDocument(_ ref: EntityRef, _ devices: Devices) async throws -> RevisionedState {
    let document = try await SchemaFixture.document(ref, in: devices.first)
    #expect(document == (try await SchemaFixture.document(ref, in: devices.second)))
    return document
  }

  @Test func shouldMergeTwoDevicesCreatingTheSameVolumeIntoOneRecord() async throws {
    let devices = try Devices()
    let volume = try Self.keyed(.volume("book-one"))
    try await SchemaFixture.set(volume.ref, ["natural_key": volume.key, "title": "Book One", "removed": false], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(volume.ref, ["natural_key": volume.key, "objective": "Escape the city", "removed": false], in: devices.second)
    try await devices.exchange()
    let record = try await Self.agreedRecord(volume.ref, devices)
    #expect(record[field: "title"]?.value == "Book One")
    #expect(record[field: "objective"]?.value == "Escape the city")
    for store in devices.both { #expect(try await SchemaFixture.count(.volume, in: store) == 1) }
  }

  private static func restore(_ ref: EntityRef, in store: VaultStore) async throws {
    let record = try await SchemaFixture.record(ref, in: store)
    var fields = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key.value, $0.value.value) })
    fields["removed"] = false
    try await SchemaFixture.set(ref, fields, in: store)
  }

  private static func entityFields(_ key: JSONValue, _ prefix: String) throws -> [String: JSONValue] {
    let schema = try #require(NovelForgeSchema.entities.first { $0.kind == NovelForgeKind.entity.entityKind })
    guard case .record(let rules) = schema.shape else { throw SchemaFixtureError(description: "entity is not a record") }
    var fields = rules.keys.reduce(into: [String: JSONValue]()) { fields, name in fields[name] = .string("\(prefix) \(name)") }
    fields["natural_key"] = key
    fields["removed"] = false
    return fields
  }

  @Test(arguments: [true, false])
  func shouldKeepARemovedRecordRemovedWhenAnEditArrivesAndShowTheEditAfterARestore(_ editLater: Bool) async throws {
    let devices = try Devices()
    let entity = try Self.keyed(.entity("aria"))
    try await SchemaFixture.set(entity.ref, ["natural_key": entity.key, "name": "Aria", "removed": false], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    if !editLater { try await SchemaFixture.set(entity.ref, ["name": "Aria Vell"], in: devices.second) }
    devices.clock.advance()
    try await SchemaFixture.set(entity.ref, ["removed": true], in: devices.first)
    devices.clock.advance()
    if editLater { try await SchemaFixture.set(entity.ref, ["name": "Aria Vell"], in: devices.second) }
    try await devices.exchange()
    let removed = try await Self.agreedRecord(entity.ref, devices)
    #expect(removed[field: "removed"]?.value == true)
    #expect(removed[field: "name"]?.value == "Aria Vell")
    devices.clock.advance()
    try await Self.restore(entity.ref, in: devices.first)
    try await devices.exchange()
    let restored = try await Self.agreedRecord(entity.ref, devices)
    #expect(restored[field: "removed"]?.value == false)
    #expect(restored[field: "name"]?.value == "Aria Vell")
  }

  @Test func shouldOverwriteEveryFieldWhenCreatingAfterARemoval() async throws {
    let devices = try Devices()
    let entity = try Self.keyed(.entity("aria"))
    try await SchemaFixture.set(entity.ref, try Self.entityFields(entity.key, "old"), in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(entity.ref, ["removed": true], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    var fields = try Self.entityFields(entity.key, "new")
    fields["notes"] = .null
    try await SchemaFixture.set(entity.ref, fields, in: devices.second)
    try await devices.exchange()
    let record = try await Self.agreedRecord(entity.ref, devices)
    for (name, value) in fields { #expect(record[field: name]?.value == value, "field \(name) was not rewritten") }
    #expect(record.fields.count == fields.count)
  }

  private static let promises: [NovelForgeKey.Components] = [.thread("the-heir"), .mystery("who-burned-the-mill")]

  @Test(arguments: promises)
  func shouldLeaveTheOpeningChapterOfAPromiseAloneOnAnOrdinaryEdit(_ components: NovelForgeKey.Components) async throws {
    let devices = try Devices()
    let promise = try Self.keyed(components)
    try await SchemaFixture.set(promise.ref, ["natural_key": promise.key, "opened_chapter": 2, "status": ["state": "open", "chapter": nil], "removed": false], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    try await SchemaFixture.set(promise.ref, ["status": ["state": "dropped", "chapter": nil]], in: devices.second)
    try await devices.exchange()
    #expect(try await Self.agreedRecord(promise.ref, devices)[field: "opened_chapter"]?.value == 2)
  }

  @Test(arguments: promises)
  func shouldReplaceTheOpeningChapterOfAPromiseRemovedAndCreatedAgain(_ components: NovelForgeKey.Components) async throws {
    let devices = try Devices()
    let promise = try Self.keyed(components)
    try await SchemaFixture.set(promise.ref, ["natural_key": promise.key, "opened_chapter": 2, "removed": false], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    try await SchemaFixture.set(promise.ref, ["removed": true], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    try await SchemaFixture.set(promise.ref, ["natural_key": promise.key, "opened_chapter": 7, "removed": false], in: devices.second)
    try await devices.exchange()
    let record = try await Self.agreedRecord(promise.ref, devices)
    #expect(record[field: "opened_chapter"]?.value == 7)
    #expect(record[field: "removed"]?.value == false)
  }

  @Test(arguments: promises)
  func shouldGiveTwoConcurrentCreatesThePromiseOpeningChapterOfTheLaterClock(_ components: NovelForgeKey.Components) async throws {
    let devices = try Devices()
    let promise = try Self.keyed(components)
    try await SchemaFixture.set(promise.ref, ["natural_key": promise.key, "opened_chapter": 2, "removed": false], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(promise.ref, ["natural_key": promise.key, "opened_chapter": 5, "removed": false], in: devices.second)
    try await devices.exchange()
    #expect(try await Self.agreedRecord(promise.ref, devices)[field: "opened_chapter"]?.value == 5)
  }

  @Test func shouldMergeAManualRevealAsARegisterAndRetractItWithARemovedFlag() async throws {
    let devices = try Devices()
    let knowledge = try Self.keyed(.characterKnowledge(fact: "heir", entity: "aria"))
    try await SchemaFixture.set(knowledge.ref, ["natural_key": knowledge.key, "reveal": ["chapter": 3, "note": "overhears it"], "removed": false], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(knowledge.ref, ["natural_key": knowledge.key, "reveal": ["chapter": 5, "note": nil], "removed": false], in: devices.second)
    try await devices.exchange()
    #expect(try await Self.agreedRecord(knowledge.ref, devices)[field: "reveal"]?.value == ["chapter": 5, "note": nil])
    devices.clock.advance()
    try await SchemaFixture.set(knowledge.ref, ["removed": true], in: devices.first)
    try await devices.exchange()
    let retracted = try await Self.agreedRecord(knowledge.ref, devices)
    #expect(retracted[field: "removed"]?.value == true)
    #expect(retracted[field: "reveal"]?.value == ["chapter": 5, "note": nil])
  }

  @Test func shouldKeepAFinalizedPlanRevisionAfterFiftyLaterRevisionsOnBothDevices() async throws {
    let devices = try Devices()
    let plan = try Self.keyed(.chapterPlan(chapter: 6))
    try await SchemaFixture.set(plan.ref, ["natural_key": plan.key, "removed": false], in: devices.first)
    let finalized = try await SchemaFixture.revise(plan.ref, ["scenes": [], "contract": "finalized"], marks: ["finalized"], in: devices.first)
    try await devices.exchange()
    for index in 1...30 { _ = try await SchemaFixture.revise(plan.ref, ["scenes": [], "contract": .string("first \(index)")], in: devices.first) }
    try await devices.exchange()
    devices.clock.advance()
    for index in 1...30 { _ = try await SchemaFixture.revise(plan.ref, ["scenes": [], "contract": .string("second \(index)")], in: devices.second) }
    try await devices.exchange()
    let merged = try await Self.agreedDocument(plan.ref, devices)
    #expect(merged.revisions.count == 51)
    #expect(merged.revisions[ExactString(finalized)] != nil)
    #expect(merged[mark: "finalized"]?.value.stringValue == finalized)
  }

  private static func canon(_ device: String) -> JSONValue {
    [
      "draft_revision": .string("v:draft-\(device)"), "plan_revision": .string("v:plan-\(device)"), "approval": .string("approval-\(device)"), "title": "The Gate",
      "body": .string("prose written on \(device)"), "note": nil, "generator": "standard", "isolated": false, "volume": "book-one",
      "contract": [
        "pov": ["aria"], "learns": [["entity": "aria", "fact": .string("fact-\(device)")]], "claimed_milestones": [.string("milestone-\(device)")],
        "is_ending": .bool(device == "second"),
      ],
    ]
  }

  @Test(arguments: [true, false])
  func shouldKeepOneWholeCanonWhenTwoDevicesFinalizeTheSameChapter(_ firstStartsEarlier: Bool) async throws {
    let devices = try Devices()
    let chapter = try Self.keyed(.finalChapter(chapter: 5))
    let (early, late) = firstStartsEarlier ? (devices.first, devices.second) : (devices.second, devices.first)
    let (earlyName, lateName) = firstStartsEarlier ? ("first", "second") : ("second", "first")
    try await SchemaFixture.set(chapter.ref, ["natural_key": chapter.key], in: early)
    devices.clock.advance()
    try await SchemaFixture.set(chapter.ref, ["natural_key": chapter.key, "canon": Self.canon(lateName)], in: late)
    devices.clock.advance()
    try await SchemaFixture.set(chapter.ref, ["canon": Self.canon(earlyName)], in: early)
    try await devices.exchange()
    let canon = try #require(try await Self.agreedDocument(chapter.ref, devices)[field: "canon"]?.value)
    #expect(canon == Self.canon(lateName))
    for member in ["draft_revision", "plan_revision", "approval", "body", "contract"] { #expect(canon[member] == Self.canon(lateName)[member], "\(member) is mixed") }
  }

  @Test(arguments: [NovelForgeKey.Components.page(section: .known(.world), slug: "magic"), .chapterPlan(chapter: 2), .draft(chapter: 2), .authorNotes])
  func shouldKeepBothConcurrentRevisionsAndHeadTheLaterOne(_ components: NovelForgeKey.Components) async throws {
    let devices = try Devices()
    let document = try Self.keyed(components)
    try await SchemaFixture.set(document.ref, ["natural_key": document.key], in: devices.first)
    let base = try await SchemaFixture.revise(document.ref, ["text": "base"], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    let mine = try await SchemaFixture.revise(document.ref, ["text": "first device"], in: devices.first)
    devices.clock.advance()
    let theirs = try await SchemaFixture.revise(document.ref, ["text": "second device"], in: devices.second)
    try await devices.exchange()
    let merged = try await Self.agreedDocument(document.ref, devices)
    #expect(Set(merged.revisions.keys.map(\.value)) == [base, mine, theirs])
    #expect(merged.headRevision == theirs)
  }

  @Test func shouldKeepTheNewestFiftyDraftRevisionsAndTheApprovedOne() async throws {
    let devices = try Devices()
    let draft = try Self.keyed(.draft(chapter: 1))
    try await SchemaFixture.set(draft.ref, ["natural_key": draft.key], in: devices.first)
    let approved = try await SchemaFixture.revise(draft.ref, ["text": "approved"], marks: ["approved"], in: devices.first)
    for index in 1...55 { _ = try await SchemaFixture.revise(draft.ref, ["text": .string("revision \(index)")], in: devices.first) }
    try await devices.exchange()
    let merged = try await Self.agreedDocument(draft.ref, devices)
    #expect(merged.revisions.count == 51)
    #expect(merged.revisions[ExactString(approved)] != nil)
    #expect(merged[mark: "approved"]?.value.stringValue == approved)
  }

  @Test func shouldKeepTheFinalChapterCanonWhileAmendmentsAccumulate() async throws {
    let devices = try Devices()
    let chapter = try Self.keyed(.finalChapter(chapter: 4))
    let canon = Self.canon("first")
    try await SchemaFixture.set(chapter.ref, ["natural_key": chapter.key, "canon": canon], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(chapter.ref, ["natural_key": chapter.key, "canon": Self.canon("second")], in: devices.second)
    try await devices.exchange()
    devices.clock.advance()
    let first = try await SchemaFixture.revise(chapter.ref, ["title": "The Gate", "body": "amended once"], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    let second = try await SchemaFixture.revise(chapter.ref, ["title": "The Gate", "body": "amended twice"], in: devices.second)
    devices.clock.advance()
    try await SchemaFixture.set(chapter.ref, ["canon": ["body": "overwritten"], "summary": "A gate opens."], in: devices.second)
    try await devices.exchange()
    let merged = try await Self.agreedDocument(chapter.ref, devices)
    #expect(merged[field: "canon"]?.value == canon)
    #expect(merged[field: "summary"]?.value == "A gate opens.")
    #expect(Set(merged.revisions.keys.map(\.value)) == [first, second])
    #expect(merged.headRevision == second)
  }

  @Test func shouldDeliverAnAppendedApprovalUnchanged() async throws {
    let devices = try Devices()
    let ref = NovelForgeKey.approval(UUID())
    let item: [String: JSONValue] = [
      "novel": .string(Self.novel.uuidString.lowercased()), "chapter": 2, "kind": "as_written", "draft_revision": "v:draft", "plan_revision": "v:plan",
      "plan_terms_digest": nil, "upstream_digest": "sha256:upstream",
    ]
    _ = try await devices.first.write { transaction in try transaction.append(ref, item: item) }
    try await devices.exchange()
    let sent = try #require(try await SchemaFixture.state(ref, in: devices.first))
    let received = try #require(try await SchemaFixture.state(ref, in: devices.second))
    guard case .appended(let appended) = received else { throw SchemaFixtureError(description: "the approval did not arrive as an appended item") }
    #expect(received == sent)
    #expect(CanonicalJSON.encode(.object(appended.item)) == CanonicalJSON.encode(.object(item)))
  }

  @Test func shouldNeverHalfMergeFieldsThatMustAgree() async throws {
    let secret = try Self.keyed(.secret("heir"))
    let cases: [(ref: EntityRef, key: JSONValue?, field: String, first: JSONValue, second: JSONValue)] = [
      (NovelForgeKey.novel(Self.novel), nil, "word_target", ["min": 1_800, "max": 2_600], ["min": 3_000, "max": 4_000]),
      (secret.ref, secret.key, "clues_and_terms", ["clues": ["a cold ring"], "terms": ["heir"]], ["clues": ["the crest"], "terms": ["bloodline"]]),
    ]
    for entry in cases {
      let devices = try Devices()
      try await SchemaFixture.set(entry.ref, [entry.field: entry.first].merging(entry.key.map { ["natural_key": $0] } ?? [:]) { $1 }, in: devices.first)
      devices.clock.advance()
      try await SchemaFixture.set(entry.ref, [entry.field: entry.second], in: devices.second)
      try await devices.exchange()
      #expect(try await Self.agreedRecord(entry.ref, devices)[field: entry.field]?.value == entry.second, "\(entry.field) merged halfway")
    }
  }
}

import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel

struct ChatSessionSubject: RecordSubject {
  static let requiredMembers: Set<String> = ["novel", "mode", "status", "removed"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = ("mode", "x_future_mode")

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> ChatSessionRecord {
    ChatSessionRecord(
      unvalidated: generator.uuid(), novel: novel, title: Gen.optionalText(&generator), autoTitle: Gen.text(&generator), mode: Gen.stored(&generator),
      status: Gen.stored(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: ChatSessionRecord) -> SubjectEdit<ChatSessionRecord> {
    let title = "Title \(generator.int(in: 0...999))"
    var edit = ChatSessionEdit()
    try? edit.rename(title)
    let (change, id) = (edit, record.id)
    return SubjectEdit(
      members: ["title"], apply: { $0.title = title }, perform: { transaction throws(StoreError) in try ChatSessionRecord.edit(id: id, change, in: &transaction) })
  }
}

extension ChatSessionEdit {
  fileprivate func renamed(_ title: String?) throws(ChatRecordError) -> ChatSessionEdit {
    var copy = self
    try copy.rename(title)
    return copy
  }

  fileprivate func named(_ title: String) throws(ChatRecordError) -> ChatSessionEdit {
    var copy = self
    try copy.nameAutomatically(title)
    return copy
  }
}

private func session(
  _ title: String? = nil, autoTitle: String? = nil, mode: ChatSessionMode = .auto, status: ChatSessionStatus = .active, in novel: UUID = novel
) throws -> ChatSessionRecord {
  try ChatSessionRecord(novel: novel, title: title, autoTitle: autoTitle, mode: mode, status: status)
}

private func read(_ record: ChatSessionRecord, in store: VaultStore) async throws -> RecordReading<ChatSessionRecord> {
  try await Harness.read(record.ref, as: ChatSessionRecord.self, in: store)
}

private func edit(_ record: ChatSessionRecord, in store: VaultStore, _ build: (inout ChatSessionEdit) throws -> Void) async throws -> ChangeRecord {
  var changes = ChatSessionEdit()
  try build(&changes)
  let (id, applied) = (record.id, changes)
  return try await store.write { transaction in try ChatSessionRecord.edit(id: id, applied, in: &transaction) }
}

@Suite("Chat session records", .timeLimit(.minutes(2)))
struct ChatSessionRecordTests {
  @Test func shouldCreateASessionUnderTheRefOfItsKeyAndReadItBack() async throws {
    let store = try SchemaFixture.store()
    let record = try session("Plot", autoTitle: "Opening", mode: .manual)
    #expect(record.ref == NovelForgeKey.chatSession(record.id))
    #expect(try await read(record, in: store) == .absent)
    let change = try await Harness.create(record, in: store)
    #expect(Set(change.fields.keys) == ["novel", "title", "auto_title", "mode", "status", "removed"])
    #expect(change.fields["removed"] == .bool(false))
    expectLive(try await read(record, in: store), record)
    #expect(try await store.read { transaction in try ChatSessionRecord.read(id: record.id, in: transaction) }.entry?.record == record)
  }

  @Test func shouldCreateAnAutoModeActiveSessionByDefault() throws {
    let record = try ChatSessionRecord(novel: novel)
    #expect(record.mode == .known(.auto))
    #expect(record.status == .known(.active))
    #expect(record.title == nil)
    #expect(record.displayTitle == nil)
  }

  @Test func shouldNeverWriteAnUntitledSessionsAutoTitleAsNull() async throws {
    let store = try SchemaFixture.store()
    let record = try session()
    let change = try await Harness.create(record, in: store)
    #expect(change.fields["auto_title"] == nil)
    #expect(change.fields["title"] == .null)
    #expect(try await SchemaFixture.record(record.ref, in: store)[field: "auto_title"] == nil)

    _ = try await edit(record, in: store) { try $0.nameAutomatically("  Opening scene  ") }
    #expect(try await read(record, in: store).entry?.record.autoTitle == "Opening scene")
  }

  @Test func shouldWriteOnlyTheMembersAnEditChanges() async throws {
    let store = try SchemaFixture.store()
    let record = try session("Plot")
    _ = try await Harness.create(record, in: store)

    var change = try await edit(record, in: store) { try $0.rename("Plot twist") }
    #expect(change.fields == ["title": "Plot twist"])
    change = try await edit(record, in: store) { try $0.rename(nil) }
    #expect(change.fields == ["title": .null])
    change = try await edit(record, in: store) { $0.switchMode(to: .manual) }
    #expect(change.fields == ["mode": "manual"])
    change = try await edit(record, in: store) { $0.setStatus(.archived) }
    #expect(change.fields == ["status": "archived"])
    var expected = record
    expected.title = nil
    expected.mode = .known(.manual)
    expected.status = .known(.archived)
    expectLive(try await read(record, in: store), expected)
  }

  @Test func shouldShowTheTitleBeforeTheAutoTitle() throws {
    #expect(try session("Mine", autoTitle: "Theirs").displayTitle == "Mine")
    #expect(try session(nil, autoTitle: "Theirs").displayTitle == "Theirs")
    #expect(try session().displayTitle == nil)
  }

  @Test func shouldRefuseBlankAndOverlongTitles() throws {
    #expect(throws: ChatRecordError.blankTitle) { try session("  \n") }
    #expect(throws: ChatRecordError.blankTitle) { try session(autoTitle: "   ") }
    #expect(throws: ChatRecordError.titleTooLong(limit: 500)) { try session(String(repeating: "x", count: 501)) }
    #expect(throws: ChatRecordError.blankTitle) { try ChatSessionEdit().renamed("") }
    #expect(throws: ChatRecordError.titleTooLong(limit: 500)) { try ChatSessionEdit().named(String(repeating: "x", count: 501)) }
    #expect(throws: Never.self) { try session(String(repeating: "😀", count: 500)) }
  }

  @Test func shouldRemoveASessionAndLetOnlyRestoreBringItBack() async throws {
    let store = try SchemaFixture.store()
    let record = try session("Plot", autoTitle: "Opening")
    _ = try await Harness.create(record, in: store)

    let removal = try await store.write { transaction in try ChatSessionRecord.remove(id: record.id, in: &transaction) }
    #expect(removal.fields == ["removed": true])
    expectRemoved(try await read(record, in: store), record)

    let renamed = try await edit(record, in: store) { try $0.rename("Renamed") }
    #expect(renamed.fields["removed"] == nil)
    var expected = record
    expected.title = "Renamed"
    expectRemoved(try await read(record, in: store), expected)

    let restoration = try await store.write { transaction in try ChatSessionRecord.restore(id: record.id, in: &transaction) }
    #expect(restoration.fields == ["removed": false])
    expectLive(try await read(record, in: store), expected)
  }

  @Test func shouldReportARefOfAnotherKindOrNotAUUIDAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let record = try session()
    let notUUID = EntityRef(kind: NovelForgeKind.chatSession.entityKind, key: EntityKey("not-a-uuid") ?? record.ref.key)
    try await SchemaFixture.set(notUUID, record.storedMembers, in: store)
    #expect(try await Harness.read(notUUID, as: ChatSessionRecord.self, in: store) == .unreadable(.identity(notUUID)))
    let novelRecord = NovelRecord(id: record.id, name: "Aria")
    _ = try await Harness.create(novelRecord, in: store)
    guard case .unreadable = try await Harness.read(novelRecord.ref, as: ChatSessionRecord.self, in: store) else {
      Issue.record("a record of another kind was read as a session")
      return
    }
  }

  @Test func shouldReadASessionTotally() async throws { try await totality(ChatSessionSubject.self, seed: 0xC501) }

  @Test func shouldKeepNewerMembersOfAStoredSessionThroughAnEdit() async throws {
    let store = try Harness.newerVersionStore()
    let record = try session("Plot")
    try await SchemaFixture.set(record.ref, record.storedMembers.merging([Harness.newerMember: ["nested": [1, 2]]]) { first, _ in first }, in: store)
    _ = try await edit(record, in: store) { try $0.rename("Next") }
    #expect(try await SchemaFixture.record(record.ref, in: store)[field: Harness.newerMember]?.value == ["nested": [1, 2]])
  }

  @Test func shouldListASessionsOfOneNovelWithItsRemovedAndUnreadableOnes() async throws {
    let store = try SchemaFixture.store()
    let (kept, gone, theirs) = (try session("Kept"), try session("Gone"), try session("Theirs", in: other))
    for record in [kept, gone, theirs] { _ = try await Harness.create(record, in: store) }
    _ = try await store.write { transaction in try ChatSessionRecord.remove(id: gone.id, in: &transaction) }
    let broken = try session("Broken")
    try await SchemaFixture.set(broken.ref, broken.storedMembers.merging(["mode": .array([.null])]) { _, wrong in wrong }, in: store)

    let listing = try await store.read { transaction in try ChatSessionRecord.listing(novel: novel, in: transaction) }
    #expect(Set(listing.entries.map(\.record.id)) == [kept.id, gone.id])
    #expect(listing.live.map(\.id) == [kept.id])
    #expect(listing.unreadable == 1)
    let all = try await store.read { transaction in try ChatSessionRecord.listing(in: transaction) }
    #expect(all.entries.count == 3)
  }

  @Test func shouldKeepTheFirstAutoTitleAndTheLaterManualTitleWhenTwoDevicesTitleTogether() async throws {
    try await forAll(iterations: 6, seed: 0xC502) { generator in
      let replicas = try await replicas(seed: generator.next())
      let record = try session(in: generator.uuid())
      _ = try await replicas.write(0) { transaction in try record.create(in: &transaction) }
      try await replicas.settle()

      var (firstName, secondName, firstRename, secondRename) = (ChatSessionEdit(), ChatSessionEdit(), ChatSessionEdit(), ChatSessionEdit())
      try firstName.nameAutomatically("First idea")
      try secondName.nameAutomatically("Second idea")
      try firstRename.rename("Mine")
      try secondRename.rename("Later mine")
      let (id, edits) = (record.id, [firstName, secondName, firstRename, secondRename])

      await replicas.advanceClock(of: 1, by: .seconds(5))
      _ = try await replicas.write(1) { transaction in try ChatSessionRecord.edit(id: id, edits[0], in: &transaction) }
      _ = try await replicas.write(1) { transaction in try ChatSessionRecord.edit(id: id, edits[2], in: &transaction) }
      await replicas.advanceClock(of: 2, by: .seconds(10))
      _ = try await replicas.write(2) { transaction in try ChatSessionRecord.edit(id: id, edits[1], in: &transaction) }
      _ = try await replicas.write(2) { transaction in try ChatSessionRecord.edit(id: id, edits[3], in: &transaction) }
      try await replicas.settle()

      var expected = record
      expected.autoTitle = "First idea"
      expected.title = "Later mine"
      try await expectAgreement(record.ref, as: ChatSessionRecord.self, in: replicas, is: live(expected))
    }
  }

  @Test func shouldKeepTheAuthorsTitleWhenAnAutoTitleArrivesFromAnotherDevice() async throws {
    let replicas = try await replicas(seed: 0xC503)
    let record = try session()
    _ = try await replicas.write(0) { transaction in try record.create(in: &transaction) }
    try await replicas.settle()
    var rename = ChatSessionEdit()
    var name = ChatSessionEdit()
    try rename.rename("Mine")
    try name.nameAutomatically("Generated")
    let (id, renaming, naming) = (record.id, rename, name)
    _ = try await replicas.write(1) { transaction in try ChatSessionRecord.edit(id: id, renaming, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(5))
    _ = try await replicas.write(2) { transaction in try ChatSessionRecord.edit(id: id, naming, in: &transaction) }
    try await replicas.settle()
    for reading in try await readings(record.ref, as: ChatSessionRecord.self, in: replicas) {
      #expect(reading.entry?.record.displayTitle == "Mine")
      #expect(reading.entry?.record.autoTitle == "Generated")
    }
  }

  @Test func shouldKeepTheFirstWritersNovelWhenTwoDevicesCreateOneSession() async throws {
    let replicas = try await replicas(seed: 0xC504)
    let id = UUID()
    let (early, late) = (try ChatSessionRecord(id: id, novel: novel), try ChatSessionRecord(id: id, novel: other))
    _ = try await replicas.write(0) { transaction in try early.create(in: &transaction) }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { transaction in try late.create(in: &transaction) }
    try await replicas.settle()
    for reading in try await readings(early.ref, as: ChatSessionRecord.self, in: replicas) { #expect(reading.entry?.record.novel == novel) }
  }

  @Test func shouldRestoreARemovedSessionOnEveryReplicaWithoutOverwritingALaterTitle() async throws {
    let replicas = try await replicas(seed: 0xC505)
    let record = try session("Plot")
    _ = try await replicas.write(0) { transaction in try record.create(in: &transaction) }
    try await replicas.settle()
    let id = record.id
    _ = try await replicas.write(0) { transaction in try ChatSessionRecord.remove(id: id, in: &transaction) }
    var rename = ChatSessionEdit()
    try rename.rename("Retitled")
    let renaming = rename
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { transaction in try ChatSessionRecord.edit(id: id, renaming, in: &transaction) }
    await replicas.advanceClock(of: 2, by: .seconds(10))
    _ = try await replicas.write(2) { transaction in try ChatSessionRecord.restore(id: id, in: &transaction) }
    try await replicas.settle()
    var expected = record
    expected.title = "Retitled"
    try await expectAgreement(record.ref, as: ChatSessionRecord.self, in: replicas, is: live(expected))
  }
}

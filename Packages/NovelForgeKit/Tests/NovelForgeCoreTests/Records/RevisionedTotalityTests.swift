import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let wrong = JSONValue.array([.null])

private func newerVersionStore() throws -> VaultStore {
  let entities = NovelForgeSchema.entities.map { schema in
    guard case .revisioned(let fields, let marks, let retention) = schema.shape else { return schema }
    return EntitySchema(
      kind: schema.kind, shape: .revisioned(fields: fields.merging([Harness.newerMember: .register]) { first, _ in first }, marks: marks, retention: retention),
      syncClass: schema.syncClass)
  }
  return try VaultStore.open(.inMemory, registry: SchemaRegistry(version: NovelForgeSchema.version, entities: entities))
}

private func readPage(slug: String, in store: VaultStore, _ mutate: (inout [String: JSONValue]) -> Void) async throws -> RecordReading<PageRecord> {
  let record = PageRecord(novel: novel, section: .plot, slug: slug)
  var members = record.storedMembers
  mutate(&members)
  try await SchemaFixture.set(record.ref, members, in: store)
  _ = try await SchemaFixture.revise(record.ref, ["body": "x"], in: store)
  return try await Harness.read(record.ref, as: PageRecord.self, in: store)
}

private func readNotes(in store: VaultStore, _ mutate: (inout [String: JSONValue]) -> Void) async throws -> RecordReading<AuthorNotesRecord> {
  let record = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "x"))
  var members = record.storedMembers
  mutate(&members)
  if !members.isEmpty { try await SchemaFixture.set(record.ref, members, in: store) }
  _ = try await SchemaFixture.revise(record.ref, ["text": "x"], in: store)
  return try await Harness.read(record.ref, as: AuthorNotesRecord.self, in: store)
}

@Suite("Revisioned record totality", TestTimeLimit.property)
struct RevisionedTotalityTests {
  @Test func shouldReadAPageWithoutANaturalKeyAsNotYetPresentAndWithoutARemovedFlagAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    #expect(try await readPage(slug: "a", in: store) { $0["natural_key"] = nil } == .absent)
    #expect(try await readPage(slug: "b", in: store) { $0["removed"] = nil } == .unreadable(.missing(field: "removed")))
  }

  @Test func shouldReportAPageWithAWrongTypedRemovedFlagAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    for (index, value) in [wrong, "false", 0, .null].enumerated() {
      #expect(try await readPage(slug: "r\(index)", in: store) { $0["removed"] = value } == .unreadable(.invalid(field: "removed")))
    }
  }

  @Test func shouldReportAPageWhoseNaturalKeyIsMalformedOrForeignAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let foreign: [JSONValue] = [
      wrong, "text", .object([:]), NovelForgeKey.secretKey(novel: novel, secret: "a").stored, NovelForgeKey.authorNotesKey(novel: novel).stored,
      NovelForgeKey.pageKey(novel: novel, section: .plot, slug: "another").stored, NovelForgeKey.pageKey(novel: SchemaFixture.otherNovel, section: .plot, slug: "k0").stored,
    ]
    for (index, key) in foreign.enumerated() {
      guard case .unreadable(.naturalKey) = try await readPage(slug: "k\(index)", in: store, { $0["natural_key"] = key }) else {
        Issue.record("natural key \(key) was accepted")
        continue
      }
    }
  }

  @Test func shouldReadAPageThatCarriesAFieldOfANewerVersion() async throws {
    let store = try newerVersionStore()
    let reading = try await readPage(slug: "n", in: store) { $0[Harness.newerMember] = ["nested": [1, 2]] }
    #expect(reading == .readable(RecordEntry(record: PageRecord(novel: novel, section: .plot, slug: "n", content: PageContent(body: "x")), isRemoved: false)))
  }

  @Test func shouldReportAPageWithAStringlyTypedSectionKeyAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let key = JSONValue.object(["novel": .string(novel.uuidString.lowercased()), "section": 3, "slug": "s"])
    guard case .unreadable(.naturalKey(.malformedKey)) = try await readPage(slug: "typed", in: store, { $0["natural_key"] = key }) else {
      Issue.record("a numeric section was accepted")
      return
    }
  }

  @Test func shouldReportNotesWithAMalformedNaturalKeyOrBodyAsUnreadable() async throws {
    let record = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "x"))
    for key in [wrong, "text", NovelForgeKey.pageKey(novel: novel, section: .plot, slug: "a").stored, NovelForgeKey.authorNotesKey(novel: SchemaFixture.otherNovel).stored]
      as [JSONValue]
    {
      let store = try SchemaFixture.store()
      guard case .unreadable(.naturalKey) = try await readNotes(in: store, { $0["natural_key"] = key }) else {
        Issue.record("natural key \(key) was accepted for notes")
        continue
      }
    }
    for body in [JSONValue.null, "text", [1], ["text": 3], ["text": nil], [:]] as [JSONValue] {
      let store = try SchemaFixture.store()
      try await SchemaFixture.set(record.ref, record.storedMembers, in: store)
      _ = try await SchemaFixture.revise(record.ref, body, in: store)
      #expect(try await Harness.read(record.ref, as: AuthorNotesRecord.self, in: store) == .unreadable(.invalid(field: "head")))
    }
    let store = try SchemaFixture.store()
    try await SchemaFixture.set(record.ref, ["natural_key": .null], in: store)
    _ = try await SchemaFixture.revise(record.ref, ["text": "x"], in: store)
    guard case .unreadable(.naturalKey) = try await Harness.read(record.ref, as: AuthorNotesRecord.self, in: store) else {
      Issue.record("a null natural key was accepted for notes")
      return
    }
  }

  @Test func shouldReadNotesWithoutANaturalKeyAsNotYetPresentAndCarryNewerBodyMembers() async throws {
    let store = try SchemaFixture.store()
    let missing = try await readNotes(in: store) { $0["natural_key"] = nil }
    #expect(missing == .absent)

    let other = try SchemaFixture.store()
    let record = AuthorNotesRecord(novel: SchemaFixture.otherNovel, content: AuthorNotesContent(text: "x"))
    try await SchemaFixture.set(record.ref, record.storedMembers, in: other)
    _ = try await SchemaFixture.revise(record.ref, ["text": "words", "mood": "dark"], in: other)
    let entry = try #require(try await Harness.read(record.ref, as: AuthorNotesRecord.self, in: other).entry)
    #expect(entry.record.content.text == "words")
    #expect(entry.record.content.unrecognised == ["mood": "dark"])
  }

  @Test func shouldReportAHistoryOfTheWrongKindOrShapeWithoutCrashing() async throws {
    let store = try SchemaFixture.store()
    let notes = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "x"))
    _ = try await Harness.create(notes, in: store)
    let asPage = try await store.read { transaction in try PageRecord.history(of: notes.ref, in: transaction) }
    #expect(asPage == .unreadable(.identity(notes.ref)))
    let volume = VolumeRecord(novel: novel, volume: "v", ordinal: 1)
    _ = try await Harness.create(volume, in: store)
    let volumeAsNotes = try await store.read { transaction in try AuthorNotesRecord.history(of: volume.ref, in: transaction) }
    #expect(volumeAsNotes == .unreadable(.identity(volume.ref)))
    let absent = try await store.read { transaction in try PageRecord.history(novel: novel, section: .ai, slug: "none", in: transaction) }
    #expect(absent == .absent)
    #expect(try await Harness.read(PageRecord.ref(novel: novel, section: .ai, slug: "none"), as: PageRecord.self, in: store) == .absent)
  }

  @Test func shouldRefuseToReviseAnEntityOfAnotherKindWithAStoreError() async throws {
    let store = try SchemaFixture.store()
    let notes = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "x"))
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try PageRecord.revise(notes.ref, body: PageContent(body: "wrong"), in: &transaction) }
    }
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try AuthorNotesRecord.revise(VolumeRecord.ref(novel: novel, volume: "v"), body: AuthorNotesContent(text: "wrong"), in: &transaction) }
    }
    #expect(try await SchemaFixture.count(.authorNotes, in: store) == 0)
  }
}

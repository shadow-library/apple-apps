import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func page(_ slug: String = "harbour", _ body: String? = "Salt and rope.", frontmatter: [String: JSONValue]? = nil, novel: UUID = novel) -> PageRecord {
  PageRecord(novel: novel, section: .world, slug: slug, content: PageContent(frontmatter: frontmatter, body: body))
}

private func history<R: RevisionedRecord>(_ ref: EntityRef, as _: R.Type, in store: VaultStore) async throws -> HistoryReading<R.Body, R.Mark> {
  try await store.read { transaction in try R.history(of: ref, in: transaction) }
}

private func revise(_ record: PageRecord, _ content: PageContent, in store: VaultStore) async throws -> Revised {
  let (section, slug) = (record.section, record.slug)
  return try await store.write { transaction in try PageRecord.revise(novel: record.novel, section: section, slug: slug, content, in: &transaction) }
}

@Suite("Revisioned records", TestTimeLimit.standard)
struct RevisionedRecordTests {
  @Test func shouldCreateAPageWithItsDocumentFieldsAndAFirstRevision() async throws {
    let store = try SchemaFixture.store()
    let record = page(frontmatter: ["title": "Harbour"])
    let created = try await Harness.create(record, in: store)
    #expect(Set(created.fields.keys) == ["natural_key", "removed"])
    #expect(created.fields["removed"] == .bool(false))
    expectLive(try await Harness.read(record.ref, as: PageRecord.self, in: store), record)

    let reading = try await history(record.ref, as: PageRecord.self, in: store)
    let entries = try #require(reading.history?.revisions)
    #expect(entries.count == 1)
    #expect(entries[0].parent == nil)
    #expect(entries[0].generation == 0)
    #expect(entries[0].body == .readable(record.content))
    #expect(reading.history?.head == entries[0].id)
    #expect(reading.history?.headEntry == entries[0])
  }

  @Test func shouldReviseAPageWithoutTouchingTheDocumentFields() async throws {
    let store = try SchemaFixture.store()
    let record = page()
    _ = try await Harness.create(record, in: store)
    let before = try await SchemaFixture.document(record.ref, in: store)
    var edited = record
    edited.content = PageContent(frontmatter: ["tags": ["port"]], body: "Gulls.")
    let revised = try await revise(edited, edited.content, in: store)
    #expect(revised.record.fields["removed"] == nil)
    #expect(revised.record.fields["natural_key"] == nil)
    expectLive(try await Harness.read(record.ref, as: PageRecord.self, in: store), edited)
    let after = try await SchemaFixture.document(record.ref, in: store)
    #expect(after.fields == before.fields)
    #expect(after.headRevision == revised.revision)
  }

  @Test func shouldListRevisionsNewestFirstWithTheirParents() async throws {
    let store = try SchemaFixture.store()
    let record = page("harbour", "v0")
    _ = try await Harness.create(record, in: store)
    var ids = [String]()
    for index in 1...4 { ids.append(try await revise(record, PageContent(body: "v\(index)"), in: store).revision) }
    let entries = try #require(try await history(record.ref, as: PageRecord.self, in: store).history?.revisions)
    #expect(entries.count == 5)
    #expect(entries.map(\.generation) == [4, 3, 2, 1, 0])
    #expect(Array(entries.map(\.id).prefix(4)) == ids.reversed())
    #expect(entries.dropLast().map(\.parent) == entries.dropFirst().map(\.id))
    #expect(entries.map { $0.body.body?.body } == ["v4", "v3", "v2", "v1", "v0"])
  }

  @Test func shouldReadAPageThatWasCreatedOverALiveOneFromTheNewestRevision() async throws {
    let store = try SchemaFixture.store()
    _ = try await Harness.create(page("harbour", "first"), in: store)
    let replacement = page("harbour", "second")
    _ = try await Harness.create(replacement, in: store)
    expectLive(try await Harness.read(replacement.ref, as: PageRecord.self, in: store), replacement)
    #expect(try await history(replacement.ref, as: PageRecord.self, in: store).history?.revisions.count == 2)
  }

  @Test func shouldRemoveAPageAndRestoreItWithoutAddingARevision() async throws {
    let store = try SchemaFixture.store()
    let record = page()
    _ = try await Harness.create(record, in: store)
    let removal = try await Harness.remove(record, in: store)
    #expect(removal.fields == ["removed": .bool(true)])
    expectRemoved(try await Harness.read(record.ref, as: PageRecord.self, in: store), record)

    let revised = try await revise(record, PageContent(body: "edited while removed"), in: store)
    #expect(revised.record.fields["removed"] == nil)
    var edited = record
    edited.content = PageContent(body: "edited while removed")
    expectRemoved(try await Harness.read(record.ref, as: PageRecord.self, in: store), edited)

    let restoration = try await Harness.restore(edited, in: store)
    #expect(Set(restoration.fields.keys) == ["natural_key", "removed"])
    expectLive(try await Harness.read(record.ref, as: PageRecord.self, in: store), edited)
    #expect(try await history(record.ref, as: PageRecord.self, in: store).history?.revisions.count == 2)
  }

  @Test func shouldCreateAndReviseTheAuthorsNotesOfANovel() async throws {
    let store = try SchemaFixture.store()
    let record = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "First idea"))
    #expect(record.ref == AuthorNotesRecord.ref(novel: novel))
    let created = try await Harness.create(record, in: store)
    #expect(Set(created.fields.keys) == ["natural_key"])
    expectLive(try await Harness.read(record.ref, as: AuthorNotesRecord.self, in: store), record)
    let revised = try await store.write { transaction in try AuthorNotesRecord.revise(novel: novel, AuthorNotesContent(text: "Second idea"), in: &transaction) }
    #expect(revised.record.fields["natural_key"] == nil)
    let expected = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "Second idea"))
    expectLive(try await store.read { transaction in try AuthorNotesRecord.read(novel: novel, in: transaction) }, expected)
    let entries = try await store.read { transaction in try AuthorNotesRecord.history(novel: novel, in: transaction) }.history?.revisions
    #expect(entries?.map { $0.body.body?.text } == ["Second idea", "First idea"])
  }

  @Test func shouldKeepOneNotesDocumentPerNovel() async throws {
    let store = try SchemaFixture.store()
    for id in [SchemaFixture.novel, SchemaFixture.otherNovel] {
      _ = try await Harness.create(AuthorNotesRecord(novel: id, content: AuthorNotesContent(text: id.uuidString)), in: store)
    }
    let first = try await store.read { transaction in try AuthorNotesRecord.read(novel: SchemaFixture.novel, in: transaction) }
    let second = try await store.read { transaction in try AuthorNotesRecord.read(novel: SchemaFixture.otherNovel, in: transaction) }
    #expect(first.entry?.record.content.text == SchemaFixture.novel.uuidString)
    #expect(second.entry?.record.content.text == SchemaFixture.otherNovel.uuidString)
    let listing = try await store.read { transaction in try AuthorNotesRecord.listing(novel: SchemaFixture.novel, in: transaction) }
    #expect(listing.entries.count == 1)
  }

  @Test func shouldCarryMembersOfANewerBodyThroughARevision() async throws {
    let store = try SchemaFixture.store()
    let record = page()
    _ = try await Harness.create(record, in: store)
    _ = try await SchemaFixture.revise(record.ref, ["body": "Salt", "frontmatter": nil, "layout": ["columns": 2]], in: store)
    let entry = try #require(try await Harness.read(record.ref, as: PageRecord.self, in: store).entry)
    #expect(entry.record.content.body == "Salt")
    #expect(entry.record.content.unrecognised == ["layout": ["columns": 2]])

    var edited = entry.record.content
    edited.body = "Salt and tar"
    let revised = try await revise(record, edited, in: store)
    let state = try await SchemaFixture.document(record.ref, in: store)
    #expect(state.revisions[ExactString(revised.revision)]?.body == ["body": "Salt and tar", "frontmatter": nil, "layout": ["columns": 2]])
  }

  @Test func shouldReadAPageThatHasOnlyItsDocumentFieldsAsNotYetPresent() async throws {
    let store = try SchemaFixture.store()
    let record = page()
    try await SchemaFixture.set(record.ref, record.storedMembers, in: store)
    #expect(try await Harness.read(record.ref, as: PageRecord.self, in: store) == .absent)
    let history = try #require(try await history(record.ref, as: PageRecord.self, in: store).history)
    #expect(history.head == nil)
    #expect(history.revisions.isEmpty)
    let listing = try await store.read { transaction in try PageRecord.listing(in: transaction) }
    #expect(listing == RecordListing(entries: [], unreadable: 0, unattributed: 0))
  }

  @Test func shouldRefuseToReviseAPageThatWasNeverCreated() async throws {
    let store = try SchemaFixture.store()
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try PageRecord.revise(novel: novel, section: .world, slug: "never", PageContent(body: "x"), in: &transaction) }
    }
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try AuthorNotesRecord.revise(novel: novel, AuthorNotesContent(text: "x"), in: &transaction) }
    }
    #expect(try await SchemaFixture.count(.page, in: store) == 0)
    #expect(try await SchemaFixture.count(.authorNotes, in: store) == 0)
  }

  @Test(arguments: [JSONValue.null, "text", 3, [1], ["body": 3], ["frontmatter": "x"], ["frontmatter": ["a": 1], "body": ["x"]]])
  func shouldReadAPageWhoseHeadBodyIsMalformedAsUnreadableAndRecoverOnTheNextRevision(_ body: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let record = page()
    _ = try await Harness.create(record, in: store)
    let broken = try await SchemaFixture.revise(record.ref, body, in: store)
    #expect(try await Harness.read(record.ref, as: PageRecord.self, in: store) == .unreadable(.invalid(field: "head")))
    let history = try #require(try await history(record.ref, as: PageRecord.self, in: store).history)
    #expect(history.head == broken)
    #expect(history.headEntry?.body == .unreadable(.invalid(field: "head")))
    #expect(history.revisions.count == 2)
    #expect(history.revisions[1].body == .readable(record.content))
    let listing = try await store.read { transaction in try PageRecord.listing(novel: novel, in: transaction) }
    #expect(listing.entries.isEmpty)
    #expect(listing.unreadable == 1)

    var fixed = record
    fixed.content = PageContent(body: "fixed")
    _ = try await revise(record, fixed.content, in: store)
    expectLive(try await Harness.read(record.ref, as: PageRecord.self, in: store), fixed)
  }
}

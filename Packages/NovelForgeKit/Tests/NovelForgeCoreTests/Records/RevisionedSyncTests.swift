import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func unknownSectionKey(_ section: String, slug: String, novel: UUID = novel) throws -> NovelForgeKey {
  try NovelForgeKey(novel: novel, .page(section: .unknown(section), slug: slug))
}

private func writeUnknownSectionPage(_ key: NovelForgeKey, body: JSONValue, in store: VaultStore) async throws {
  try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "removed": false], in: store)
  _ = try await SchemaFixture.revise(key.ref, body, in: store)
}

@Suite("Revisioned records over time and replicas", .timeLimit(.minutes(2)))
struct RevisionedSyncTests {
  @Test func shouldReadAPageAsNotYetPresentUntilBothHalvesOfItsCreateHaveArrived() async throws {
    let record = PageRecord(novel: novel, section: .world, slug: "split", content: PageContent(body: "whole"))
    try await splitDelivery(record, in: [[0, 1], [1, 0]], as: PageRecord.self)
  }

  @Test func shouldReadTheNotesAsNotYetPresentUntilBothHalvesOfTheirCreateHaveArrived() async throws {
    let record = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "whole"))
    try await splitDelivery(record, in: [[0, 1], [1, 0]], as: AuthorNotesRecord.self)
  }

  @Test func shouldTakeMarksFromTheStoreIndependentlyOfTheHead() async throws {
    let store = try SchemaFixture.store()
    let stub = try RevisionedStubRecord(novel: novel, chapter: 4, content: PageContent(body: "v0"))
    _ = try await Harness.create(stub, in: store)
    let first = try await store.write { transaction in try RevisionedStubRecord.revise(stub.ref, body: PageContent(body: "approved"), marks: [.approved], in: &transaction) }
    let second = try await store.write { transaction in try RevisionedStubRecord.revise(stub.ref, body: PageContent(body: "later"), in: &transaction) }
    let history = try #require(try await Harness.history(stub.ref, as: RevisionedStubRecord.self, in: store).history)
    #expect(history.marks == [.approved: first.revision])
    #expect(history.head == second.revision)
    #expect(history.headEntry?.body == .readable(PageContent(body: "later")))
    #expect(history.revisions.first { $0.id == first.revision }?.body == .readable(PageContent(body: "approved")))
    #expect(try await Harness.read(stub.ref, as: RevisionedStubRecord.self, in: store).entry?.record.content == PageContent(body: "later"))
  }

  @Test func shouldHaveNoMarksForPagesAndNotes() async throws {
    let store = try SchemaFixture.store()
    let record = PageRecord(novel: novel, section: .power, slug: "rank", content: PageContent(body: "b"))
    _ = try await Harness.create(record, in: store)
    #expect(try await Harness.history(record.ref, as: PageRecord.self, in: store).history?.marks == [:])
  }

  @Test func shouldKeepTheNewestFiftyRevisionsAndTheHead() async throws {
    let store = try SchemaFixture.store()
    let record = PageRecord(novel: novel, section: .ai, slug: "style", content: PageContent(body: "0"))
    _ = try await Harness.create(record, in: store)
    for index in 1...60 {
      _ = try await store.write { transaction in try PageRecord.revise(novel: novel, section: .ai, slug: "style", PageContent(body: "\(index)"), in: &transaction) }
    }
    let history = try #require(try await Harness.history(record.ref, as: PageRecord.self, in: store).history)
    #expect(history.revisions.count == NovelForgeSchema.revisionLimit)
    #expect(history.revisions.first?.body == .readable(PageContent(body: "60")))
    #expect(history.headEntry == history.revisions.first)
    #expect(try await Harness.read(record.ref, as: PageRecord.self, in: store).entry?.record.content.body == "60")
  }

  @Test func shouldSkipAPageOfAnUnknownSectionInReadsAndListingsAndLeaveItUntouched() async throws {
    let store = try SchemaFixture.store()
    let key = try unknownSectionKey("bestiary", slug: "wolves")
    try await writeUnknownSectionPage(key, body: ["body": "Grey", "frontmatter": nil, "bestiary_tier": 3], in: store)
    let known = PageRecord(novel: novel, section: .world, slug: "wolves", content: PageContent(body: "Known"))
    _ = try await Harness.create(known, in: store)
    let before = try await SchemaFixture.document(key.ref, in: store)

    #expect(try await Harness.read(key.ref, as: PageRecord.self, in: store) == .unreadable(.unknownSection("bestiary")))
    let listing = try await store.read { transaction in try PageRecord.listing(novel: novel, in: transaction) }
    #expect(listing.entries.map(\.record) == [known])
    #expect(listing.unreadable == 0)
    #expect(listing.unattributed == 0)
    let everything = try await store.read { transaction in try PageRecord.listing(in: transaction) }
    #expect(everything.entries.map(\.record) == [known])
    #expect(everything.unreadable == 0)

    let edited = PageContent(body: "Edited")
    _ = try await store.write { transaction in try PageRecord.revise(novel: novel, section: .world, slug: "wolves", edited, in: &transaction) }
    _ = try await Harness.remove(known, in: store)
    #expect(try await SchemaFixture.document(key.ref, in: store) == before)
  }

  @Test func shouldKeepAPageOfAnUnknownSectionByteForByteAcrossDevices() async throws {
    let devices = try Devices()
    let key = try unknownSectionKey("bestiary", slug: "wolves")
    let body: JSONValue = ["body": "Grey", "frontmatter": ["tier": 3], "bestiary_tier": [1, 2]]
    try await writeUnknownSectionPage(key, body: body, in: devices.first)
    try await devices.exchange()
    let sent = try await SchemaFixture.document(key.ref, in: devices.first)
    let received = try await SchemaFixture.document(key.ref, in: devices.second)
    #expect(received == sent)
    let revision = try #require(received.headRevision)
    #expect(CanonicalJSON.encode(try #require(received.revisions[ExactString(revision)]).body) == CanonicalJSON.encode(body))
    for store in devices.both {
      #expect(try await Harness.read(key.ref, as: PageRecord.self, in: store) == .unreadable(.unknownSection("bestiary")))
      #expect(try await store.read { transaction in try PageRecord.listing(novel: novel, in: transaction) }.entries.isEmpty)
    }
  }

  @Test func shouldTellAnUnknownSectionApartFromAMalformedKey() async throws {
    let store = try SchemaFixture.store()
    let key = try unknownSectionKey("bestiary", slug: "wolves")
    try await writeUnknownSectionPage(key, body: ["body": 3], in: store)
    #expect(try await Harness.read(key.ref, as: PageRecord.self, in: store) == .unreadable(.unknownSection("bestiary")))
    let broken = PageRecord(novel: novel, section: .lore, slug: "broken")
    try await SchemaFixture.set(broken.ref, broken.storedMembers, in: store)
    _ = try await SchemaFixture.revise(broken.ref, ["body": 3], in: store)
    let listing = try await store.read { transaction in try PageRecord.listing(novel: novel, in: transaction) }
    #expect(listing.unreadable == 1)
  }

  @Test func shouldListOnlyThePagesOfTheNovelWithRemovedOnesMarked() async throws {
    let store = try SchemaFixture.store()
    let mine = (0..<3).map { PageRecord(novel: novel, section: .storyState, slug: "mine-\($0)", content: PageContent(body: "\($0)")) }
    let gone = PageRecord(novel: novel, section: .lore, slug: "gone")
    let theirs = PageRecord(novel: SchemaFixture.otherNovel, section: .storyState, slug: "mine-0")
    for record in mine + [gone, theirs] { _ = try await Harness.create(record, in: store) }
    _ = try await Harness.remove(gone, in: store)
    let listing = try await store.read { transaction in try PageRecord.listing(novel: novel, in: transaction) }
    #expect(listing.unreadable == 0)
    #expect(Set(listing.live.map(\.ref)) == Set(mine.map(\.ref)))
    #expect(listing.entries.first { $0.record.ref == gone.ref }?.isRemoved == true)
    #expect(listing.entries.count == 4)
    let others = try await store.read { transaction in try PageRecord.listing(novel: SchemaFixture.otherNovel, in: transaction) }
    #expect(others.entries.map(\.record) == [theirs])
  }

  @Test func shouldConvergeConcurrentRevisionsOfAPageAndKeepBothInTheHistory() async throws {
    try await forAll(iterations: 8, seed: 0x71) { generator in
      let replicas = try await replicas(seed: generator.next())
      let record = PageRecord(novel: generator.uuid(), section: .plot, slug: Gen.key(&generator), content: PageContent(body: Gen.text(&generator)))
      _ = try await replicas.write(0) { transaction in try record.create(in: &transaction) }
      try await replicas.settle()
      let (left, right) = (PageContent(body: "left-" + Gen.text(&generator)), PageContent(body: "right-" + Gen.text(&generator)))
      let (section, slug, id) = (record.section, record.slug, record.novel)
      _ = try await replicas.write(1) { transaction in try PageRecord.revise(novel: id, section: section, slug: slug, left, in: &transaction) }
      await replicas.advanceClock(of: 2, by: .seconds(5))
      _ = try await replicas.write(2) { transaction in try PageRecord.revise(novel: id, section: section, slug: slug, right, in: &transaction) }
      try await replicas.settle()

      var readings = [RecordReading<PageRecord>]()
      var histories = [HistoryReading<PageContent, NoMark>]()
      for index in 0..<replicas.count {
        let store = await replicas.store(index)
        readings.append(try await Harness.read(record.ref, as: PageRecord.self, in: store))
        histories.append(try await store.read { transaction in try PageRecord.history(of: record.ref, in: transaction) })
      }
      for reading in readings.dropFirst() { #expect(reading == readings[0]) }
      for history in histories.dropFirst() { #expect(history == histories[0]) }
      #expect(readings[0].entry?.record.content == right)
      let bodies = try #require(histories[0].history).revisions.compactMap { $0.body.body }
      for expected in [left, right, record.content] { #expect(bodies.contains(expected)) }
    }
  }

  @Test func shouldSettleRandomPageWorkToTheSameStateOnEveryReplica() async throws {
    try await forAll(iterations: 30, seed: 0x72) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let pages = ["a", "b"].map { PageRecord(novel: id, section: .world, slug: $0, content: PageContent(body: $0)) }
      for _ in 0..<14 {
        let page = generator.pick(from: pages)
        let index = generator.int(in: 0...2)
        let (section, slug) = (page.section, page.slug)
        switch generator.int(in: 0...99) {
        case 0..<20:
          let content = PageContent(body: Gen.text(&generator))
          _ = try await replicas.write(index) { transaction in try PageRecord(novel: id, section: section, slug: slug, content: content).create(in: &transaction) }
        case 20..<50:
          let content = PageContent(body: Gen.text(&generator))
          _ = try await replicas.write(index) { transaction in
            guard case .readable = try PageRecord.read(novel: id, section: section, slug: slug, in: transaction) else { return false }
            _ = try PageRecord.revise(novel: id, section: section, slug: slug, content, in: &transaction)
            return true
          }
        case 50..<60:
          _ = try await replicas.write(index) { transaction in try PageRecord.remove(novel: id, section: section, slug: slug, in: &transaction) }
        case 60..<70:
          _ = try await replicas.write(index) { transaction in try PageRecord(novel: id, section: section, slug: slug).restore(in: &transaction) }
        case 70..<80:
          await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3)))
        default:
          _ = try await replicas.step(using: &generator)
        }
      }
      try await replicas.settle()
      var listings = [RecordListing<PageRecord>]()
      for index in 0..<replicas.count {
        listings.append(try await replicas.store(index).read { transaction in try PageRecord.listing(novel: id, in: transaction) })
      }
      for listing in listings.dropFirst() { #expect(listing == listings[0]) }
    }
  }
}

func splitDelivery<R: DocumentRecord>(_ record: R, in orders: [[Int]], as _: R.Type) async throws {
  for order in orders {
    let devices = try Devices()
    _ = try await devices.first.write { transaction in try record.create(in: &transaction) }
    let lines = try await devices.first.pendingChanges(limit: Int.max).map(\.line)
    #expect(lines.count == 2)
    for (position, index) in order.enumerated() {
      _ = try await devices.second.applyRemote([lines[index]])
      let reading = try await Harness.read(record.ref, as: R.self, in: devices.second)
      let listing = try await devices.second.read { transaction in try R.listing(in: transaction) }
      if position == 0 {
        #expect(reading == .absent, "after \(order)")
        #expect(listing == RecordListing(entries: [], unreadable: 0, unattributed: 0), "after \(order)")
      } else {
        #expect(reading == .readable(RecordEntry(record: record, isRemoved: false)), "after \(order)")
        #expect(listing.entries.map(\.record) == [record], "after \(order)")
      }
    }
  }
}

extension Harness {
  static func history<R: RevisionedRecord>(_ ref: EntityRef, as _: R.Type, in store: VaultStore) async throws -> HistoryReading<R.Body, R.Mark> {
    try await store.read { transaction in try R.history(of: ref, in: transaction) }
  }
}

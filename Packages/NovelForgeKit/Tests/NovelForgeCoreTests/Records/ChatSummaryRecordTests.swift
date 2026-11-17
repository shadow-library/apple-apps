import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel
private let session = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000b1")
private let wrong = JSONValue.array([.null])

extension Gen {
  static func chatSummary(_ generator: inout SeededGenerator, novel: UUID, session: UUID = session) throws -> ChatSummaryRecord {
    try ChatSummaryRecord(
      id: generator.uuid(), novel: novel, session: session, covered: (0..<generator.int(in: 1...6)).map { _ in generator.uuid() }, text: Gen.text(&generator) + "s",
      contentMode: generator.pick(from: ContentMode.allCases))
  }
}

private func append(_ record: ChatSummaryRecord, in store: VaultStore) async throws -> ChangeRecord {
  try await store.write { transaction in try record.append(in: &transaction) }
}

private func appendRaw(_ ref: EntityRef, _ item: [String: JSONValue], in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.append(ref, item: item) }
}

private func read(_ ref: EntityRef, in store: VaultStore) async throws -> AppendedReading<ChatSummaryRecord> {
  try await store.read { transaction in try ChatSummaryRecord.read(ref, in: transaction) }
}

@Suite("Chat summary records", .timeLimit(.minutes(2)))
struct ChatSummaryRecordTests {
  @Test func shouldRoundTripSummariesUnderTheRefOfTheirId() async throws {
    let store = try SchemaFixture.store()
    try await forAll(iterations: 40, seed: 0xC701) { generator in
      let record = try Gen.chatSummary(&generator, novel: generator.uuid())
      #expect(record.ref == NovelForgeKey.chatSummary(record.id))
      #expect(try await read(record.ref, in: store) == .absent)
      let change = try await append(record, in: store)
      #expect(Set(change.fields.keys) == Set(ChatSummaryMember.allCases.map(\.rawValue)))
      #expect(try await read(record.ref, in: store) == .readable(AppendedEntry(record: record, clock: change.clock)))
      #expect(try await store.read { transaction in try ChatSummaryRecord.read(id: record.id, in: transaction) }.entry?.record == record)
    }
  }

  @Test func shouldReadASummaryTotally() async throws {
    let store = try SchemaFixture.store()
    try await forAll(iterations: 3, seed: 0xC702) { generator in
      for name in try Gen.chatSummary(&generator, novel: novel).item.keys.sorted() {
        let missing = try Gen.chatSummary(&generator, novel: novel)
        var item = missing.item
        item[name] = nil
        try await appendRaw(missing.ref, item, in: store)
        #expect(try await read(missing.ref, in: store) == .unreadable(.missing(field: name)), "missing \(name)")

        let corrupt = try Gen.chatSummary(&generator, novel: novel)
        item = corrupt.item
        item[name] = wrong
        try await appendRaw(corrupt.ref, item, in: store)
        #expect(try await read(corrupt.ref, in: store) == .unreadable(.invalid(field: name)), "wrong type \(name)")
      }
    }
  }

  @Test func shouldReportASummaryWhoseCoveredIdsAreNotAllUUIDsAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC703)
    let record = try Gen.chatSummary(&generator, novel: novel)
    try await appendRaw(record.ref, record.item.merging(["covered": ["not-a-uuid"]]) { _, bad in bad }, in: store)
    #expect(try await read(record.ref, in: store) == .unreadable(.invalid(field: "covered")))
  }

  @Test func shouldKeepNewerMembersAndAnUnknownContentMode() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC704)
    let record = try Gen.chatSummary(&generator, novel: novel)
    var item = record.item
    item[Harness.newerMember] = ["nested": [1, 2]]
    item["content_mode"] = "x_mode"
    try await appendRaw(record.ref, item, in: store)
    let carried = try #require(try await read(record.ref, in: store).entry?.record)
    #expect(carried.item == item)
    #expect(carried.contentMode == .unknown("x_mode"))
  }

  @Test func shouldRefuseASummaryThatCoversNothingOrSaysNothing() throws {
    #expect(throws: ChatRecordError.noCoveredMessages) { try ChatSummaryRecord(novel: novel, session: session, covered: [], text: "x", contentMode: .standard) }
    #expect(throws: ChatRecordError.blankSummary) { try ChatSummaryRecord(novel: novel, session: session, covered: [UUID()], text: "", contentMode: .standard) }
  }

  @Test func shouldListOneSessionsSummariesOldestFirst() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC705)
    var mine = [AppendedEntry<ChatSummaryRecord>]()
    for _ in 0..<3 {
      let record = try Gen.chatSummary(&generator, novel: novel)
      mine.append(AppendedEntry(record: record, clock: try await append(record, in: store).clock))
    }
    _ = try await append(try Gen.chatSummary(&generator, novel: novel, session: generator.uuid()), in: store)
    _ = try await append(try Gen.chatSummary(&generator, novel: other), in: store)
    let listing = try await store.read { transaction in try ChatSummaryRecord.listing(session: session, novel: novel, in: transaction) }
    #expect(listing.records == mine.map(\.record))
    #expect(listing.unreadable == 0)
  }
}

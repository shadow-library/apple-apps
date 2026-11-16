import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func pair() throws -> (reconciler: NovelForgeReconciler, writer: VaultStore, reader: VaultStore) {
  let reconciler = try Projection.reconciler()
  return (reconciler, try Projection.store(reconciler), try Projection.store(reconciler))
}

private func expectConsistent(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

private func fieldNames(of kind: NovelForgeKind) -> [String] {
  switch Projection.registry[kind.entityKind]?.shape {
  case .record(let fields)?: fields.keys.sorted()
  case .revisioned(let fields, _, _)?: fields.keys.sorted()
  case .appended?, nil: []
  }
}

private func randomValue(_ generator: inout SeededGenerator, keys: [JSONValue]) -> JSONValue {
  switch generator.int(in: 0...8) {
  case 0: .null
  case 1: .bool(generator.chance(0.5))
  case 2: .int(Int64(generator.int(in: -3...3)))
  case 3: .string(Gen.text(&generator))
  case 4: .array([.int(1)])
  case 5: .object(["body": .string("b")])
  case 6: Projection.canon().json
  default: generator.pick(from: keys)
  }
}

private func isDataFailure(_ error: any Error) -> Bool {
  guard let error = error as? StoreError else { return true }
  switch error {
  case .invalidChange, .entityPurged: return false
  default: return true
  }
}

@Suite("Projection totality", .timeLimit(.minutes(3)))
struct ProjectionTotalityTests {
  @Test func shouldCountACanonThisVersionCannotReadAsFinal() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 1)
    try await Projection.set(key.ref, ["natural_key": key.stored, "canon": .string("garbage")], in: store)
    let finals = try await Projection.finals(in: store)
    #expect(
      finals.map { [$0.key.rawValue, "\($0.chapter)", "\($0.isReadable)", $0.canonDigest ?? "-", $0.draftRevision ?? "-"] } == [
        [key.ref.key.rawValue, "1", "false", FinalChapterRecord.digest(.string("garbage")), "-"]
      ])
    #expect(finals.first?.canonClock != nil)
    #expect(try await Projection.cursors(in: store) == [novel: 2])
    #expect(try await Projection.indexed(key.ref, in: store)?.status == .unreadable)
    #expect(try await Projection.indexed(key.ref, in: store)?.novel == novel)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldIgnoreAFinalChapterWhoseKeyNamesAnotherChapter() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: 2)
    let wrong = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 3)
    try await Projection.set(ref, ["natural_key": wrong.stored, "canon": Projection.canon().json], in: store)
    #expect(try await Projection.finals(in: store).isEmpty)
    #expect(try await Projection.cursors(in: store).isEmpty)
    #expect(try await Projection.entry(ref, in: store) == IndexEntry(ref: ref, novel: nil, status: .unreadable))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldWaitForTheCanonWhenItsAmendmentArrivesFirst() async throws {
    let (reconciler, writer, reader) = try pair()
    try await Projection.finalize(novel: novel, chapter: 1, in: writer)
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: 1)
    _ = try await Projection.write(writer) { transaction in try FinalChapterRecord.amend(ref, FinalChapterText(body: "Amended."), in: &transaction) }
    let lines = try await Projection.lines(of: writer)
    #expect(lines.count == 2)

    try await Projection.apply([lines[1]], to: reader)
    #expect(try await Projection.finals(in: reader).isEmpty)
    #expect(try await Projection.indexed(ref, in: reader) == nil)
    try await expectConsistent(reconciler, in: reader)

    try await Projection.apply([lines[0]], to: reader)
    #expect(try await Projection.finals(in: reader).map(\.chapter) == [1])
    #expect(try await Projection.cursors(in: reader) == [novel: 2])
    #expect(try await Projection.derived(reconciler, in: reader) == (try await Projection.derived(reconciler, in: writer)))
  }

  @Test func shouldIndexAHalfDeliveredDraftOnlyOnceItsHeadArrives() async throws {
    let (reconciler, writer, reader) = try pair()
    let draft = try DraftRecord(novel: novel, chapter: 1, content: DraftContent(body: "Waves.", source: .known(.generated)))
    _ = try await Projection.write(writer) { transaction in try draft.create(in: &transaction) }
    let lines = try await Projection.lines(of: writer)
    #expect(lines.count == 2)

    try await Projection.apply([lines[0]], to: reader)
    #expect(try await Projection.indexed(draft.ref, in: reader) == nil)
    try await expectConsistent(reconciler, in: reader)

    try await Projection.apply([lines[1]], to: reader)
    #expect(try await Projection.indexed(draft.ref, in: reader)?.status == .live)
    try await expectConsistent(reconciler, in: reader)
  }

  @Test func shouldIndexARecordWithNoNaturalKeyUnderNoNovel() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    let ref = NovelForgeKey.volume(novel: novel, key: "one")
    try await Projection.set(ref, ["removed": .bool(false)], in: store)
    #expect(try await Projection.entry(ref, in: store) == IndexEntry(ref: ref, novel: nil, status: .unreadable))
  }

  @Test func shouldIndexAnAppendedItemMissingMembersUnderItsNovel() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    let ref = NovelForgeKey.approval(SchemaFixture.otherNovel)
    _ = try await Projection.write(store) { transaction in try transaction.append(ref, item: ["novel": .string(novel.uuidString.lowercased())]) }
    #expect(try await Projection.entry(ref, in: store) == IndexEntry(ref: ref, novel: novel, status: .unreadable))
  }

  @Test func shouldApplyARecordFromANewerVersion() async throws {
    let reconciler = try Projection.reconciler()
    let reader = try Projection.store(reconciler)
    let newer = try Harness.newerVersionStore()
    let ref = NovelForgeKey.novel(novel)
    _ = try await newer.write { transaction in
      try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      return try transaction.set(ref, [Harness.newerMember: .string("later")])
    }
    try await Projection.apply(try await Projection.lines(of: newer), to: reader)
    #expect(try await Projection.indexed(ref, in: reader)?.status == .live)
    #expect(try await Projection.cursors(in: reader) == [novel: 1])
    try await expectConsistent(reconciler, in: reader)
  }

  @Test func shouldPassOverRecordsOfUnknownKindsAndUnparseableLines() async throws {
    let (reconciler, writer, reader) = try pair()
    try await Projection.createNovel(novel, in: writer)
    let line = try #require(try await Projection.lines(of: writer).first)
    let foreign = Data(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\"nf_novel\"", with: "\"nf_future_kind\"").utf8)
    #expect(foreign != line)
    let result = try await Projection.apply([foreign, Data("not a change".utf8)], to: reader)
    #expect(result.opaque == 1)
    #expect(try await Projection.derived(reconciler, in: reader).values.allSatisfy(\.isEmpty))
    try await expectConsistent(reconciler, in: reader)
  }

  @Test func shouldDropPurgedEntitiesAndMoveTheCursorBack() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: store)
    for chapter in [1, 2] { try await Projection.finalize(novel: novel, chapter: chapter, in: store) }
    try await Projection.purge(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: store)
    #expect(try await Projection.finals(in: store).map(\.chapter) == [2])
    #expect(try await Projection.cursors(in: store) == [novel: 1])

    try await Projection.purge(NovelForgeKey.novel(novel), in: store)
    #expect(try await Projection.indexed(NovelForgeKey.novel(novel), in: store) == nil)
    #expect(try await Projection.cursors(in: store) == [novel: 1])

    try await Projection.purge(try FinalChapterRecord.ref(novel: novel, chapter: 2), in: store)
    #expect(try await Projection.cursors(in: store).isEmpty)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldNeverFailToReconcileArbitraryStoredValues() async throws {
    let reconciler = try Projection.reconciler()
    try await forAll(iterations: 12, seed: 0xD13) { generator in
      let store = try Projection.store(reconciler)
      let novels = [novel, SchemaFixture.otherNovel]
      let keys = try [
        NovelForgeKey.finalChapterKey(novel: novel, chapter: 1), NovelForgeKey.finalChapterKey(novel: novel, chapter: 2),
        NovelForgeKey.draftKey(novel: novel, chapter: 1), NovelForgeKey.volumeKey(novel: novel, volume: "one"), NovelForgeKey.authorNotesKey(novel: novel),
      ]
      let storedKeys = keys.map(\.stored) + [.object(["novel": .string("x")])]
      let refs = keys.map(\.ref) + novels.map(NovelForgeKey.novel) + [NovelForgeKey.approval(novel), NovelForgeKey.notebookEntry(novel)]
      for _ in 0..<16 {
        let ref = generator.pick(from: refs)
        let kind = try #require(NovelForgeKind(ref.kind))
        let value = randomValue(&generator, keys: storedKeys)
        let item: [String: JSONValue] = ["novel": generator.pick(from: [.string(novel.uuidString.lowercased()), .int(1)]), "statement": value]
        let names = fieldNames(of: kind)
        let fields = Dictionary(uniqueKeysWithValues: names.filter { _ in generator.chance(0.5) }.map { ($0, randomValue(&generator, keys: storedKeys)) })
        let action = generator.int(in: 0...9)
        do {
          _ = try await Projection.write(store) { transaction in
            switch action {
            case 0: _ = try transaction.purge(ref)
            case 1...3 where kind == .approval || kind == .notebookEntry: _ = try transaction.append(ref, item: item)
            case 4...5 where !names.isEmpty && fieldNames(of: kind).contains("natural_key"): _ = try transaction.revise(ref, body: value)
            default: _ = try transaction.set(ref, fields.isEmpty ? ["natural_key": value] : fields)
            }
          }
        } catch {
          #expect(!isDataFailure(error), "\(error)")
        }
      }
      let comparison = try await Projection.compare(reconciler, in: store)
      #expect(comparison.incremental == comparison.rebuilt)
      #expect(try await Projection.faults(reconciler, in: store).isEmpty)
    }
  }
}

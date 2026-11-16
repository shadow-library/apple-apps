import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

typealias BibleBody = @Sendable (inout WriteTransaction) throws -> Void

struct BibleWorld: Sendable {
  let store: VaultStore
  let novel: UUID

  static func make(withNovel: Bool = true) async throws -> BibleWorld {
    let world = BibleWorld(store: try SchemaFixture.store(), novel: SchemaFixture.novel)
    if withNovel { _ = try await Harness.create(NovelRecord(id: world.novel, name: "Ember"), in: world.store) }
    return world
  }

  func run(_ body: BibleBody) async throws {
    try await store.write(body)
  }

  func expect(_ expected: BibleError, _ body: BibleBody, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
      try await store.write(body)
      Issue.record("expected \(expected.code) but the operation succeeded", sourceLocation: sourceLocation)
    } catch {
      guard case .aborted(let cause) = error else {
        Issue.record("expected \(expected.code) but got \(error)", sourceLocation: sourceLocation)
        return
      }
      #expect(cause as? BibleError == expected, sourceLocation: sourceLocation)
    }
  }

  func entity(_ key: String) async throws -> RecordReading<EntityRecord> {
    let novel = novel
    return try await store.read { try EntityRecord.read(novel: novel, entity: key, in: $0) }
  }

  func page(_ section: BiblePageSection, _ slug: String) async throws -> RecordReading<PageRecord> {
    let novel = novel
    return try await store.read { try PageRecord.read(novel: novel, section: section, slug: slug, in: $0) }
  }

  func versions(_ section: BiblePageSection, _ slug: String) async throws -> [PageVersion] {
    let novel = novel
    return try await store.read { try Pages.versions(novel: novel, section: section, slug: slug, in: $0) }
  }

  func pendingChangeCount() async throws -> Int {
    try await store.pendingChanges(limit: Int.max).count
  }
}

func liveRecord<R: Sendable & Equatable>(_ reading: RecordReading<R>) -> R? {
  guard case .readable(let entry) = reading, !entry.isRemoved else { return nil }
  return entry.record
}

func removedRecord<R: Sendable & Equatable>(_ reading: RecordReading<R>) -> Bool {
  guard case .readable(let entry) = reading else { return false }
  return entry.isRemoved
}

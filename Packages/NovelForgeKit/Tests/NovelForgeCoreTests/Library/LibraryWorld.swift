import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

typealias LibraryBody = @Sendable (inout WriteTransaction) throws -> Void

struct LibraryWorld: Sendable {
  let store: VaultStore

  static func make() throws -> LibraryWorld { LibraryWorld(store: try SchemaFixture.store()) }

  func run(_ body: LibraryBody) async throws {
    try await store.write(body)
  }

  func create(_ input: NewNovel, id: UUID = UUID()) async throws -> UUID {
    try await store.writeDomain { transaction throws(DomainError) in try Library.create(input, id: id, in: &transaction) }
  }

  func expect(_ expected: DomainError, _ body: LibraryBody, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
      try await store.write(body)
      Issue.record("expected \(expected.code) but the operation succeeded", sourceLocation: sourceLocation)
    } catch {
      guard case .aborted(let cause) = error else {
        Issue.record("expected \(expected.code) but got \(error)", sourceLocation: sourceLocation)
        return
      }
      #expect(cause as? DomainError == expected, sourceLocation: sourceLocation)
    }
  }

  func novel(_ id: UUID) async throws -> NovelRecord? {
    try await store.read { try Library.novel(id, in: $0) }
  }

  func notes(_ id: UUID) async throws -> String {
    try await store.read { try Library.notes(novel: id, in: $0) }
  }

  func list() async throws -> NovelList {
    try await store.read { try Library.novels(in: $0) }
  }

  func archivedList() async throws -> NovelList {
    try await store.read { try Library.archivedNovels(in: $0) }
  }

  func pendingChangeCount() async throws -> Int {
    try await store.pendingChanges(limit: Int.max).count
  }
}

func changing(_ build: (inout NovelChanges) -> Void) -> NovelChanges {
  var changes = NovelChanges()
  build(&changes)
  return changes
}

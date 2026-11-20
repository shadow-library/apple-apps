import Foundation
import ShadowCore
import ShadowStore
import ShadowText

@testable import NovelForgeCore

enum NotebookFixture {
  static let novel = SchemaFixture.novel
  static let other = SchemaFixture.otherNovel
  static let replica = ReplicaID(SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000aa"))

  static func clock(_ millis: Int64, counter: UInt16 = 0) -> HLCTimestamp {
    guard let clock = HLCTimestamp(wallMillis: millis, counter: counter, replica: replica) else { preconditionFailure("\(millis) is a valid clock") }
    return clock
  }

  static func entry(
    _ id: UUID = UUID(), novel: UUID = novel, supersedes: UUID? = nil, at millis: Int64, topic: String = "premise"
  ) -> AppendedEntry<NotebookEntryRecord> {
    AppendedEntry(record: NotebookEntryRecord(id: id, novel: novel, entryKind: .known(.decision), topic: topic, statement: "s", supersedes: supersedes), clock: clock(millis))
  }

  static func withdrawal(of entry: UUID, novel: UUID = novel, at millis: Int64) -> AppendedEntry<NotebookWithdrawalRecord> {
    AppendedEntry(record: NotebookWithdrawalRecord(novel: novel, entry: entry, reason: "r"), clock: clock(millis))
  }

  static func store(novel: UUID? = novel) async throws -> VaultStore {
    let store = try SchemaFixture.store()
    if let novel { _ = try await store.write { transaction in try NovelRecord(id: novel, name: "Ember").create(in: &transaction) } }
    return store
  }

  static func attempt<T: Sendable>(_ store: VaultStore, _ body: @Sendable (inout WriteTransaction) throws(NotebookError) -> T) async throws -> Result<T, NotebookError> {
    try await store.write { transaction in
      do throws(NotebookError) { return .success(try body(&transaction)) } catch { return .failure(error) }
    }
  }

  static func ledger(_ store: VaultStore, novel: UUID = novel) async throws -> NotebookLedger {
    try await store.read { transaction in try NotebookLedger.load(novel: novel, in: transaction) }
  }

  static func decision(_ topic: String = "premise", statement: String = "A lighthouse keeper") -> NewNotebookEntry {
    NewNotebookEntry(kind: .decision, topic: topic, statement: statement, decidedBy: .author)
  }

  static func rejection(_ idea: String, scope: LedgerRejectionScope = .never, anchor: JSONValue? = nil, topic: String? = nil) -> NewNotebookEntry {
    NewNotebookEntry(
      kind: .rejected, topic: topic ?? NotebookTopics.idea(idea), statement: "No", decidedBy: .author, idea: NotebookIdeaRejection(ideaId: idea, scope: scope, anchor: anchor))
  }
}

extension Result {
  var failure: Failure? {
    guard case .failure(let error) = self else { return nil }
    return error
  }

  var success: Success? {
    guard case .success(let value) = self else { return nil }
    return value
  }
}

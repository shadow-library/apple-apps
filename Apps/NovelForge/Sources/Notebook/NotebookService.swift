import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct NotebookService: Sendable {
  let store: VaultStore
  let novel: UUID

  func add(_ entry: AuthorNotebookEntry) async throws(NotebookError) -> UUID {
    let novel = novel
    return try await write { transaction throws(NotebookError) in try Notebook.recordByAuthor(entry, novel: novel, in: &transaction).id }
  }

  func rewrite(_ id: UUID, as rewrite: NotebookRewrite) async throws(NotebookError) -> UUID {
    let novel = novel
    return try await write { transaction throws(NotebookError) in try Notebook.supersedeByAuthor(id, rewrite: rewrite, novel: novel, in: &transaction).id }
  }

  func withdraw(_ id: UUID, reason: String) async throws(NotebookError) {
    let novel = novel
    try await write { transaction throws(NotebookError) in _ = try Notebook.withdraw(id, reason: reason, novel: novel, in: &transaction) }
  }

  private func write<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(NotebookError) -> T) async throws(NotebookError) -> T {
    do {
      return try await store.write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let notebook = cause as? NotebookError { throw notebook }
      throw .store(error)
    }
  }
}

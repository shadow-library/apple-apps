import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct LibraryService: Sendable {
  let store: VaultStore

  func create(title: String, notes: String) async throws(DomainError) -> UUID {
    let input = NewNovel(title: title, notes: notes.isEmpty ? nil : notes)
    return try await store.writeDomain { transaction throws(DomainError) in try Library.create(input, in: &transaction) }
  }

  func edit(novel: UUID, title: String?, notes: String?) async throws(DomainError) {
    try await store.writeDomain { transaction throws(DomainError) in
      if let title {
        var changes = NovelChanges()
        changes.title = .set(title)
        try Library.edit(novel: novel, changes, in: &transaction)
      }
      if let notes { try Library.replaceNotes(novel: novel, text: notes, in: &transaction) }
    }
  }

  func clone(source: UUID, name: String) async throws(DomainError) -> UUID {
    let copy = NovelCopy(name: name)
    return try await store.writeDomain { transaction throws(DomainError) in try Library.clone(novel: source, as: copy, in: &transaction) }
  }

  func setArchived(_ archived: Bool, novel: UUID) async throws(DomainError) {
    try await store.writeDomain { transaction throws(DomainError) in
      if archived { try Library.archive(novel: novel, in: &transaction) } else { try Library.restore(novel: novel, in: &transaction) }
    }
  }

  func notes(novel: UUID) async throws(DomainError) -> String {
    do {
      return try await store.read { transaction in try Library.notes(novel: novel, in: transaction) }
    } catch {
      if case .aborted(let cause) = error, let domain = cause as? DomainError { throw domain }
      throw .store(error)
    }
  }
}

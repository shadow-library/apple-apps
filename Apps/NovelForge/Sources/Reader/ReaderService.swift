import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct ReaderService: Sendable {
  let store: VaultStore
  let novel: UUID

  func save(chapter: Int, title: String?, body: String, base: String?) async throws(DomainError) -> DraftSaveOutcome {
    let novel = novel
    let now = store.wallClock()
    let edit = DraftEdit(title: title, body: body)
    return try await store.writeDomain { transaction throws(DomainError) in
      try ChapterDrafts.save(novel: novel, chapter: chapter, edit, base: base, at: now, in: &transaction)
    }
  }

  func commitWorkingCopy(chapter: Int) async throws(DomainError) -> String? {
    let novel = novel
    return try await store.writeDomain { transaction throws(DomainError) in try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: chapter, in: &transaction) }
  }

  func startNext() async throws(DomainError) -> Int {
    let novel = novel
    return try await store.writeDomain { transaction throws(DomainError) in try ChapterDrafts.startNext(novel: novel, in: &transaction) }
  }

  func importDraft(chapter: Int, prose: String, base: String?) async throws(DomainError) -> String {
    let novel = novel
    let draft = DraftImport(prose: prose)
    return try await store.writeDomain { transaction throws(DomainError) in try ChapterDrafts.importDraft(novel: novel, chapter: chapter, draft, base: base, in: &transaction) }
  }

  func restore(chapter: Int, revision: String, base: String?) async throws(DomainError) -> String {
    let novel = novel
    return try await store.writeDomain { transaction throws(DomainError) in
      try DraftVersions.restore(novel: novel, chapter: chapter, revision: revision, base: base, in: &transaction)
    }
  }

  func hold(chapter: Int, title: String?, body: String, base: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      try ChapterDrafts.hold(novel: novel, chapter: chapter, title: title, body: body, base: base, in: &transaction)
    }
  }

  func discardWorkingCopy(chapter: Int) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try ChapterDrafts.discardWorkingCopy(novel: novel, chapter: chapter, in: transaction) }
  }
}

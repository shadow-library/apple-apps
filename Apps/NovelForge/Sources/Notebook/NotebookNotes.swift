import Foundation
import NovelForgeCore
import Observation

@MainActor
@Observable
final class NotebookNotes {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(PresentedError)
  }

  var text = ""
  private(set) var stored = ""
  private(set) var phase = Phase.idle
  private(set) var isSaving = false
  private(set) var saveFailure: PresentedError?
  private let novel: UUID
  private let service: LibraryService

  init(context: NovelContext) {
    novel = context.novel
    service = LibraryService(store: context.store)
  }

  var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
  var words: Int { LibraryCounting.words(in: text) }
  var wordsOver: Int { max(words - LibraryLimits.notesWords, 0) }
  var isEditable: Bool { phase == .loaded }
  var hasChanges: Bool { phase == .loaded && trimmed != stored }
  var withinLimits: Bool { words <= LibraryLimits.notesWords && LibraryCounting.characters(in: text) <= LibraryLimits.notesCharacters }
  var canSave: Bool { hasChanges && withinLimits && !isSaving }

  func load() async {
    guard phase == .idle || isFailed else { return }
    phase = .loading
    do {
      stored = try await service.notes(novel: novel)
      text = stored
      phase = .loaded
    } catch {
      phase = .failed(NotebookErrors.present(error))
    }
  }

  func revert() {
    text = stored
    saveFailure = nil
  }

  func save() async {
    guard canSave else { return }
    isSaving = true
    saveFailure = nil
    defer { isSaving = false }
    let notes = trimmed
    do {
      try await service.edit(novel: novel, title: nil, notes: notes)
      stored = notes
      text = notes
    } catch {
      saveFailure = NotebookErrors.present(error)
    }
  }

  func flush() {
    guard canSave else { return }
    Task { await save() }
  }

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }
}

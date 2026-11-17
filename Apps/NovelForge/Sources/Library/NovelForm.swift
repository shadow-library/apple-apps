import Foundation
import NovelForgeCore
import Observation

enum NovelFormMode: Equatable {
  case create
  case edit(novel: UUID, title: String)
  case clone(source: UUID, title: String)
}

enum NotesLoad: Equatable {
  case idle
  case loading
  case loaded(String)
  case failed(PresentedError)
}

@MainActor
@Observable
final class NovelForm {
  static let untitledName = "Untitled novel"

  let mode: NovelFormMode
  var title: String
  var notes = ""
  private(set) var issues = NovelFormIssues.none
  private(set) var isSubmitting = false
  private(set) var notesLoad = NotesLoad.idle

  init(mode: NovelFormMode) {
    self.mode = mode
    switch mode {
    case .create, .clone: title = ""
    case .edit(_, let title): self.title = title
    }
  }

  var titleLimit: Int { mode.titleLimit }
  var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
  var notesWords: Int { LibraryCounting.words(in: notes) }
  var notesWordsOver: Int { max(notesWords - LibraryLimits.notesWords, 0) }
  var notesWordsLeft: Int { max(LibraryLimits.notesWords - notesWords, 0) }

  var showsNotes: Bool {
    if case .clone = mode { return false }
    return true
  }

  var titleIssue: String? {
    guard LibraryCounting.characters(in: title) <= titleLimit else { return NovelFormIssues.titleTooLong(titleLimit) }
    return issues.title
  }

  var notesIssue: String? {
    if notesWords > LibraryLimits.notesWords { return NovelFormIssues.notesOverWords }
    if LibraryCounting.characters(in: notes) > LibraryLimits.notesCharacters { return NovelFormIssues.notesOverCharacters }
    return issues.notes
  }

  var notesEditable: Bool {
    switch mode {
    case .create: true
    case .edit: isNotesLoaded
    case .clone: false
    }
  }

  var hasChanges: Bool {
    switch mode {
    case .create: !trimmedTitle.isEmpty || !trimmedNotes.isEmpty
    case .edit(_, let original): changedTitle(original) != nil || changedNotes != nil
    case .clone: !trimmedTitle.isEmpty
    }
  }

  var canSubmit: Bool {
    guard !isSubmitting, withinLimits else { return false }
    switch mode {
    case .create: return true
    case .edit(_, let original): return changedTitle(original) != nil || changedNotes != nil
    case .clone: return !trimmedTitle.isEmpty
    }
  }

  func edited() {
    issues = .none
  }

  func loadNotes(using library: LibraryModel) async {
    guard case .edit(let novel, _) = mode, notesLoad == .idle || isNotesFailed else { return }
    notesLoad = .loading
    do {
      let stored = try await library.loadNotes(novel: novel)
      notes = stored
      notesLoad = .loaded(stored)
    } catch {
      notesLoad = .failed(PresentedError(error, known: LibraryErrors.headline))
    }
  }

  func submit(using library: LibraryModel) async -> UUID? {
    guard canSubmit else { return nil }
    isSubmitting = true
    issues = .none
    defer { isSubmitting = false }
    do {
      switch mode {
      case .create: return try await library.create(title: trimmedTitle.isEmpty ? Self.untitledName : trimmedTitle, notes: trimmedNotes)
      case .edit(let novel, let original):
        try await library.edit(novel: novel, title: changedTitle(original), notes: changedNotes)
        return novel
      case .clone(let source, _): return try await library.clone(source: source, name: trimmedTitle)
      }
    } catch {
      issues = NovelFormIssues(error)
      return nil
    }
  }

  private var withinLimits: Bool {
    LibraryCounting.characters(in: title) <= titleLimit && notesWords <= LibraryLimits.notesWords
      && LibraryCounting.characters(in: notes) <= LibraryLimits.notesCharacters
  }

  private var isNotesLoaded: Bool {
    guard case .loaded = notesLoad else { return false }
    return true
  }

  private var isNotesFailed: Bool {
    guard case .failed = notesLoad else { return false }
    return true
  }

  private func changedTitle(_ original: String) -> String? {
    trimmedTitle == original ? nil : trimmedTitle
  }

  private var changedNotes: String? {
    guard case .loaded(let stored) = notesLoad, trimmedNotes != stored.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return trimmedNotes
  }
}

extension NovelFormMode {
  fileprivate var titleLimit: Int {
    switch self {
    case .edit: LibraryLimits.titleCharactersOnEdit
    case .create, .clone: LibraryLimits.titleCharactersOnCreate
    }
  }
}

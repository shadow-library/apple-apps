import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

@MainActor
@Observable
final class NotebookNotes {
  enum Phase: Equatable {
    case loading
    case loaded
    case unreadable
    case failed(PresentedError)
  }

  var text = "" {
    didSet { updateRegistration() }
  }
  private(set) var stored = ""
  private(set) var generation = 0
  private(set) var isSaving = false
  private(set) var saveFailure: PresentedError?
  private(set) var storedChangedWhileEditing = false
  private let store: VaultStore
  private let novel: UUID
  private let service: LibraryService
  private let unsavedWork: UnsavedWork
  private let observer = ReadObserver<NovelNotes>()
  @ObservationIgnored private var registration: UUID?
  @ObservationIgnored private var hasLoaded = false

  init(context: NovelContext, unsavedWork: UnsavedWork = .shared) {
    store = context.store
    novel = context.novel
    service = LibraryService(store: context.store)
    self.unsavedWork = unsavedWork
  }

  var phase: Phase {
    switch observer.state {
    case .loading: .loading
    case .failed(let error): .failed(error)
    case .loaded(let notes): notes.notes == .unreadable ? .unreadable : .loaded
    }
  }

  private var storedTrimmed: String { stored.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
  var words: Int { LibraryCounting.words(in: text) }
  var wordsOver: Int { max(words - LibraryLimits.notesWords, 0) }
  var isEditable: Bool { phase == .loaded }
  var hasChanges: Bool { phase == .loaded && trimmed != storedTrimmed }
  var hasNewerVersion: Bool { storedChangedWhileEditing && hasChanges }
  var withinLimits: Bool { words <= LibraryLimits.notesWords && LibraryCounting.characters(in: text) <= LibraryLimits.notesCharacters }
  var canSave: Bool { hasChanges && withinLimits && !isSaving }

  func observe() async {
    let store = store
    let novel = novel
    await observer.run({ store.observe(NovelNotes.self, novel) }, onValue: { [self] value in apply(value.notes) })
    updateRegistration()
  }

  func retry() {
    generation += 1
  }

  func revert() {
    text = stored
    storedChangedWhileEditing = false
    saveFailure = nil
  }

  func save() async {
    guard canSave else { return }
    isSaving = true
    saveFailure = nil
    defer { isSaving = false }
    let notes = trimmed
    let submitted = text
    let previous = stored
    do {
      try await service.edit(novel: novel, title: nil, notes: notes)
      finishSave(notes, submitted: submitted, previousStored: previous)
    } catch {
      saveFailure = NotebookErrors.present(error)
    }
  }

  func finishSave(_ notes: String, submitted: String, previousStored: String) {
    guard stored == previousStored else { return }
    stored = notes
    if text == submitted { text = notes }
    storedChangedWhileEditing = false
  }

  func flush() {
    guard canSave else { return }
    Task { await save() }
  }

  isolated deinit {
    if let registration { unsavedWork.unregister(registration) }
  }

  private func apply(_ reading: NotesReading) {
    guard case .text(let incoming) = reading else {
      updateRegistration()
      return
    }
    guard hasLoaded else {
      hasLoaded = true
      stored = incoming
      text = incoming
      return
    }
    guard incoming != stored else { return }
    let wasEditing = hasChanges
    stored = incoming
    switch (wasEditing, trimmed == storedTrimmed) {
    case (false, _):
      text = incoming
      storedChangedWhileEditing = false
    case (true, true): storedChangedWhileEditing = false
    case (true, false): storedChangedWhileEditing = true
    }
    updateRegistration()
  }

  private func updateRegistration() {
    guard hasLoaded else { return }
    switch (hasChanges, registration) {
    case (true, nil): registration = unsavedWork.register { [weak self] in await self?.save() }
    case (false, .some(let token)):
      unsavedWork.unregister(token)
      registration = nil
    default: return
    }
  }
}

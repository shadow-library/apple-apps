import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell

@MainActor
@Observable
final class ReaderModel {
  var failure: ActionFailure?
  private(set) var isStarting = false
  let service: ReaderService
  private var editors: [Int: ChapterEditorModel] = [:]
  private var registrations: [Int: UUID] = [:]
  private let unsavedWork: UnsavedWork

  init(context: NovelContext, unsavedWork: UnsavedWork = .shared) {
    self.unsavedWork = unsavedWork
    service = ReaderService(store: context.store, novel: context.novel)
  }

  func editor(for chapter: Int, draft: ChapterContent.Draft) -> ChapterEditorModel {
    if let existing = editors[chapter] { return existing }
    let created = ChapterEditorModel(chapter: chapter, draft: draft, service: service)
    editors[chapter] = created
    registrations[chapter] = unsavedWork.register { await created.flush() }
    return created
  }

  func existingEditor(for chapter: Int) -> ChapterEditorModel? {
    editors[chapter]
  }

  func hasUnsavedWork(in chapter: Int) -> Bool {
    editors[chapter]?.needsAttention ?? false
  }

  func release(_ chapter: Int) {
    guard let editor = editors[chapter], !editor.needsAttention else { return }
    drop(chapter)
  }

  func drop(_ chapter: Int) {
    editors[chapter]?.cancelAutosave()
    editors[chapter] = nil
    if let token = registrations.removeValue(forKey: chapter) { unsavedWork.unregister(token) }
  }

  var hasUnsavedWork: Bool {
    editors.values.contains { $0.needsAttention }
  }

  func startNext() async -> Int? {
    guard !isStarting else { return nil }
    isStarting = true
    defer { isStarting = false }
    do {
      return try await service.startNext()
    } catch {
      fail(error)
      return nil
    }
  }

  func importProse(_ prose: String, into chapter: Int, currentRevision: String? = nil) async -> Bool {
    let editor = editors[chapter]
    var base = currentRevision
    if let editor {
      guard let settled = await editor.settledBase() else { return false }
      base = settled
    }
    do {
      _ = try await service.importDraft(chapter: chapter, prose: prose, base: base)
      return true
    } catch {
      fail(error)
      return false
    }
  }

  func restore(revision: String, in chapter: Int, current: String) async -> Bool {
    var base = current
    if let editor = editors[chapter] {
      guard let settled = await editor.settledBase() else { return false }
      base = settled
    }
    do {
      _ = try await service.restore(chapter: chapter, revision: revision, base: base)
      return true
    } catch {
      fail(error)
      return false
    }
  }

  func discardKept(in chapter: Int) async {
    do {
      try await service.discardWorkingCopy(chapter: chapter)
    } catch {
      fail(error)
    }
  }

  isolated deinit {
    registrations.values.forEach(unsavedWork.unregister)
  }

  func fail(_ error: any Error) {
    failure = ActionFailure(error: ReaderErrors.presented(error))
  }
}

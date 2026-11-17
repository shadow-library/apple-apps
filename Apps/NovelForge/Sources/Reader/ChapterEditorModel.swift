import Foundation
import NovelForgeCore
import Observation

enum EditorStatus: Equatable {
  case idle
  case saving
  case conflict
  case locked
  case deleted
  case failed(PresentedError)

  // platform/apps/novel-forge-web/src/lib/chapter-editor.ts:leaveWarning
  var leaveWarning: String {
    switch self {
    case .conflict:
      String(
        localized:
          "A newer version of this chapter arrived and your edits are waiting for you to choose between them. They stay on this device, not in the chapter, and can be shown, copied or discarded from the chapter afterwards.",
        table: "Reader")
    case .locked:
      String(
        localized:
          "This chapter was finalized, so your edits cannot be saved to it. They stay on this device, not in the chapter, and can be shown, copied or discarded from the chapter afterwards.",
        table: "Reader")
    case .deleted:
      String(
        localized:
          "This chapter's draft was removed, so your edits cannot be saved to it. They stay on this device, not in the chapter, and can be shown, copied or discarded from the chapter afterwards.",
        table: "Reader")
    case .idle, .saving, .failed:
      String(
        localized: "Your latest edits to this chapter are not saved to it yet. They stay on this device and can be shown, copied or discarded from the chapter afterwards.",
        table: "Reader")
    }
  }
}

@MainActor
@Observable
final class ChapterEditorModel {
  static let autosaveDelay: Duration = .milliseconds(750)
  static let autosaveMaximumWait: Duration = .seconds(5)

  let chapter: Int
  var text: ChapterText
  private(set) var status = EditorStatus.idle
  private(set) var theirs: ChapterContent.Draft?
  private(set) var base: String
  private(set) var words: Int
  private var saved: ChapterText
  private var held: Bool
  private var latest: ChapterContent.Draft
  @ObservationIgnored private let service: ReaderService
  @ObservationIgnored private let delay: Duration
  @ObservationIgnored private let maximumWait: Duration
  @ObservationIgnored private var autosave: Task<Void, Never>?
  @ObservationIgnored private var counting: Task<Void, Never>?
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var pendingSince: ContinuousClock.Instant?

  init(
    chapter: Int, draft: ChapterContent.Draft, service: ReaderService, autosaveDelay: Duration = ChapterEditorModel.autosaveDelay,
    maximumWait: Duration = ChapterEditorModel.autosaveMaximumWait
  ) {
    self.chapter = chapter
    self.service = service
    delay = autosaveDelay
    self.maximumWait = maximumWait
    base = draft.revision
    text = draft.editable
    saved = draft.editable
    held = draft.working != nil
    latest = draft
    words = WordCount.words(in: draft.editable.body)
  }

  var isDirty: Bool { text != saved }
  var isEditable: Bool { status != .locked && status != .deleted }
  var isBlocked: Bool {
    switch status {
    case .conflict, .locked, .deleted: true
    case .idle, .saving, .failed: false
    }
  }

  var needsAttention: Bool {
    switch status {
    case .idle, .locked, .deleted: isDirty
    case .saving, .conflict, .failed: true
    }
  }

  var canSave: Bool {
    switch status {
    case .idle, .failed: true
    case .saving, .conflict, .locked, .deleted: false
    }
  }

  func textChanged() {
    autosave?.cancel()
    autosave = nil
    scheduleCount()
    if case .failed = status { status = .idle }
    guard isDirty, canSave else { return }
    let now = ContinuousClock.now
    let since = pendingSince ?? now
    pendingSince = since
    let wait = min(delay, max(.zero, maximumWait - (now - since)))
    autosave = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled else { return }
      _ = await self?.save()
    }
  }

  @discardableResult
  func save() async -> Bool {
    autosave?.cancel()
    autosave = nil
    for _ in 0..<3 {
      if let flight { await flight.value }
      guard isDirty, canSave else { break }
      pendingSince = nil
      let write = Task { await self.write() }
      flight = write
      await write.value
      flight = nil
    }
    return !isDirty && status == .idle
  }

  func finish() async -> Bool {
    guard await save() else {
      await hold()
      return false
    }
    return await commit()
  }

  func flush() async {
    guard !(await save()) else { return }
    await hold()
  }

  func settledBase() async -> String? {
    guard await save(), await commit() else { return nil }
    return base
  }

  func keepMine() {
    guard status == .conflict, let theirs else { return }
    base = theirs.revision
    held = false
    self.theirs = nil
    status = .idle
    textChanged()
  }

  func takeTheirs() -> ChapterText? {
    guard let theirs else { return nil }
    let replaced = text
    adopt(theirs)
    return replaced
  }

  func restore(_ replaced: ChapterText) {
    text = replaced
    textChanged()
  }

  func retry() {
    guard case .failed = status else { return }
    status = .idle
    textChanged()
  }

  func leave() {
    cancelAutosave()
    text = saved
    theirs = nil
    status = .idle
  }

  func reconcile(with draft: ChapterContent.Draft) {
    latest = draft
    guard status != .saving else { return }
    if draft.revision == base {
      if status == .conflict {
        theirs = nil
        status = .idle
      }
      return
    }
    if draft.head == saved || draft.editable == saved {
      base = draft.revision
      held = draft.working != nil
      theirs = nil
      if status == .conflict { status = .idle }
      return
    }
    if status == .conflict {
      theirs = draft
      return
    }
    guard isDirty else { return adopt(draft) }
    theirs = draft
    status = .conflict
    cancelAutosave()
  }

  func reconcileFinal() {
    guard status != .saving else { return }
    status = .locked
    cancelAutosave()
  }

  func reconcileMissing() {
    guard status != .saving else { return }
    status = .deleted
    cancelAutosave()
  }

  func cancelAutosave() {
    autosave?.cancel()
    autosave = nil
  }

  private func scheduleCount() {
    counting?.cancel()
    counting = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      words = WordCount.words(in: text.body)
    }
  }

  private func adopt(_ draft: ChapterContent.Draft) {
    base = draft.revision
    text = draft.editable
    saved = draft.editable
    held = draft.working != nil
    theirs = nil
    words = WordCount.words(in: text.body)
    status = status == .locked ? .locked : .idle
  }

  private func write() async {
    let sent = text
    let title = sent.title.isEmpty && saved.title.isEmpty ? nil : sent.title
    status = .saving
    for attempt in 0..<2 {
      do {
        let outcome = try await service.save(chapter: chapter, title: title, body: sent.body, base: base)
        base = outcome.base
        saved = sent
        status = .idle
        switch outcome {
        case .committed: held = false
        case .held: held = true
        case .unchanged: break
        }
        return
      } catch {
        if attempt == 0, case .draftConflict(_, let head) = error, head == latest.revision, head != base, latest.head == saved || latest.editable == saved {
          base = latest.revision
          continue
        }
        refuse(error)
        return
      }
    }
  }

  private func commit() async -> Bool {
    guard held else { return true }
    status = .saving
    do {
      if let revision = try await service.commitWorkingCopy(chapter: chapter) { base = revision }
      held = false
      status = .idle
      return true
    } catch {
      refuse(error)
      return false
    }
  }

  private func hold() async {
    guard isDirty, status != .saving else { return }
    let title = text.title.isEmpty && saved.title.isEmpty ? nil : text.title
    do {
      try await service.hold(chapter: chapter, title: title, body: text.body, base: base)
    } catch {
      if status == .idle { status = .failed(ReaderErrors.presented(error)) }
    }
  }

  private func refuse(_ error: DomainError) {
    switch error {
    case .draftConflict(_, let head):
      status = .conflict
      theirs = head == latest.revision && head != base ? latest : nil
    case .draftFinal: status = .locked
    case .draftNotFound: status = .deleted
    default: status = .failed(ReaderErrors.presented(error))
    }
  }
}

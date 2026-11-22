import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// `features/quick-logs/journal-screen.tsx`: today's entry with an optional mood, the entries with search, and the writing rail.
@MainActor
@Observable
final class JournalModel {
  static let pageSize = 20

  let context: MemoirScreenContext
  let overview = ReadObserver<JournalOverview>()
  let caps = ReadObserver<EntryCapsOverview>()
  var text = ""
  var mood: Int?
  var search = "" {
    didSet { if search != oldValue { visibleCount = Self.pageSize } }
  }
  private(set) var visibleCount = pageSize
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  private(set) var confirmation: String?

  init(context: MemoirScreenContext) {
    self.context = context
  }

  func observe() async {
    let context = context
    let stores = context.stores
    let days = LogStreams.days(context)
    async let overview: Void = overview.run { LogStreams.following(days) { today in LogReads.observeJournal(in: stores, today: today) } }
    async let caps: Void = caps.run { LogStreams.entryCaps(context) }
    _ = await (overview, caps)
  }

  var canSave: Bool { !isSaving && !trimmed.isEmpty }

  var advisory: EntryCapAdvisory? { caps.state.value?.advisory(.journal) }

  /// Pressing the selected mood clears it: mood is optional, so it must be un-answerable.
  func toggleMood(_ value: Int) {
    mood = mood == value ? nil : value
  }

  func apply(_ tool: MarkdownTool, selectionStart: Int, selectionEnd: Int) -> MarkdownTool.Edit {
    let edit = tool.apply(to: text, selectionStart: selectionStart, selectionEnd: selectionEnd)
    text = edit.text
    return edit
  }

  /// The entry is the owner's text as typed; only a blank one is refused. A failed save keeps the text and the mood.
  @discardableResult
  func save() async -> Bool {
    guard canSave else { return false }
    isSaving = true
    defer { isSaving = false }
    failure = nil
    confirmation = nil
    do {
      let today = try await context.today()
      let id = UUID()
      let record = JournalEntryRecord(id: id, date: today.date, text: text, mood: mood, loggedAtMillis: MemoirClock.millis(context.clock.now()))
      try await context.writer.issue(.journalSave(QuickLogEntry(id: id, date: today.date)), creating: record)
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
    text = ""
    mood = nil
    confirmation = String(localized: "Entry saved.", table: "Log")
    return true
  }

  func entries(in overview: JournalOverview) -> [JournalEntrySummary] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return overview.entries }
    return overview.entries.filter { $0.entry.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }

  func showMore() {
    visibleCount += Self.pageSize
  }

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

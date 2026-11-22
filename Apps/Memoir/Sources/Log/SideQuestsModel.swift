import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// `features/quick-logs/side-quests-screen.tsx`: something done that no quest asked for, with the day's three rewarded entries and the month's XP.
@MainActor
@Observable
final class SideQuestsModel {
  static let pageSize = 20
  static let statOrder: [StatAffinity] = [.discipline, .body, .wealth, .mind]

  let context: MemoirScreenContext
  let overview = ReadObserver<SideQuestsOverview>()
  let caps = ReadObserver<EntryCapsOverview>()
  var name = ""
  var stat = StatAffinity.discipline
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
    async let overview: Void = overview.run { LogStreams.following(days) { today in LogReads.observeSideQuests(in: stores, today: today) } }
    async let caps: Void = caps.run { LogStreams.entryCaps(context) }
    _ = await (overview, caps)
  }

  var advisory: EntryCapAdvisory? { caps.state.value?.advisory(.sideQuests) }

  var canSave: Bool { !isSaving && !trimmedName.isEmpty }

  /// Every entry records; replay decides whether it took one of the day's rewarded slots.
  @discardableResult
  func save() async -> Bool {
    guard canSave else { return false }
    let name = trimmedName
    isSaving = true
    defer { isSaving = false }
    failure = nil
    confirmation = nil
    do {
      let today = try await context.today()
      let id = UUID()
      let record = SideQuestRecord(id: id, date: today.date, name: name, loggedAtMillis: MemoirClock.millis(context.clock.now()))
      try await context.writer.issue(.sideQuestLog(SideQuestEntry(id: id, date: today.date, statAffinity: stat)), creating: record)
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
    self.name = ""
    confirmation = String(localized: "\(name) logged.", table: "Log")
    return true
  }

  func items(in overview: SideQuestsOverview) -> [SideQuestsOverview.Item] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return overview.items }
    return overview.items.filter { $0.sideQuest.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }

  func showMore() {
    visibleCount += Self.pageSize
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

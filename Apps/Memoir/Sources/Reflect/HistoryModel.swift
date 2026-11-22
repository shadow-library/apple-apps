import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

struct HistoryReadKey: Hashable {
  let query: HistoryQuery
  let today: LocalDate
}

/// `features/history/index.tsx`: one stream of everything logged, filtered by kind, searched and paged, with the selected record's details.
@MainActor
@Observable
final class HistoryModel {
  static let filters: [HistoryKind?] = [nil] + HistoryKind.allCases.map { $0 }
  static let searchPause = Duration.milliseconds(250)

  private let context: MemoirScreenContext
  let bodyClasses: Set<SyncClass>
  let day: ReflectDayFollower
  let history = ReadObserver<HistoryPage>()
  let lookups = ReadObserver<ReflectLookups>()
  private(set) var kind: HistoryKind?
  private(set) var search = ""
  /// What is typed in the search field; it becomes `search` once typing pauses.
  var searchText = ""
  private(set) var page = 1
  var selection: String?

  init(context: MemoirScreenContext, bodyClasses: Set<SyncClass> = ReflectBody.onThisDevice) {
    self.context = context
    self.bodyClasses = bodyClasses
    day = ReflectDayFollower(context: context)
  }

  var query: HistoryQuery? {
    try? HistoryQuery.page(page, kinds: kind.map { [$0] }, search: search, categoryNames: ReflectCopy.builtInCategoryNames)
  }

  var readKey: HistoryReadKey? {
    guard let today = day.day?.today, let query else { return nil }
    return HistoryReadKey(query: query, today: today)
  }

  var isFiltered: Bool {
    kind != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var pageCount: Int {
    guard let total = history.state.value?.records.total else { return 1 }
    return max(1, (total + HistoryQuery.pageSize - 1) / HistoryQuery.pageSize)
  }

  var rows: [HistoryPresentation] {
    guard let page = history.state.value else { return [] }
    return page.records.items.map { HistoryPresentation($0, day: day.day, lookups: lookups.state.value, home: page.totals.spent?.home) }
  }

  var groups: [HistoryGroup] {
    HistoryGroup.grouping(rows, today: day.day?.today)
  }

  /// The kind's class is not read on this device, so the filter can only come up empty.
  var kindIsNotHeld: Bool {
    switch kind {
    case .weight: !bodyClasses.contains(.health)
    case .health: bodyClasses.isDisjoint(with: [.activity, .health])
    default: false
    }
  }

  func filter(_ kind: HistoryKind?) {
    guard kind != self.kind else { return }
    self.kind = kind
    page = 1
  }

  func setSearch(_ text: String) {
    guard text != search else { return }
    search = text
    page = 1
  }

  /// Applies what was typed once it has stood for `searchPause`, so a read does not restart on every keystroke.
  func applySearchAfterPause() async {
    let text = searchText
    guard text != search else { return }
    do {
      try await Task.sleep(for: Self.searchPause)
    } catch {
      return
    }
    setSearch(text)
  }

  func clearFilters() {
    kind = nil
    search = ""
    searchText = ""
    page = 1
  }

  func go(to page: Int) {
    self.page = min(max(1, page), pageCount)
  }

  func followToday() async {
    await day.follow()
  }

  func observe() async {
    guard let key = readKey else { return }
    let stores = context.stores
    let bodyClasses = bodyClasses
    await history.run {
      ReflectReads.observeHistory(in: stores, matching: key.query, bodyClasses: bodyClasses, today: key.today)
    } onValue: { [weak self] page in
      self?.settle(page)
    }
  }

  func observeLookups() async {
    let main = context.stores.main
    await lookups.run { main.observe(ReflectLookups.self, ReflectLookupsQuery(streaks: false)) }
  }

  /// A page past the end, after records went away elsewhere, moves back to the last page, as the reference clamps it.
  private func settle(_ received: HistoryPage) {
    guard received.records.items.isEmpty, page > 1 else { return }
    page = max(1, (received.records.total + HistoryQuery.pageSize - 1) / HistoryQuery.pageSize)
  }
}

enum HistoryRecordState: Equatable {
  case loading
  case failed(PresentedError)
  /// No longer among the records the filter and search keep, or no longer recorded at all.
  case missing
  case found(HistoryPresentation)
}

/// One record's details, found among the records a filter and search keep.
@MainActor
@Observable
final class HistoryRecordModel {
  private let context: MemoirScreenContext
  let id: String
  let bodyClasses: Set<SyncClass>
  let day: ReflectDayFollower
  let history = ReadObserver<HistoryPage>()
  let lookups = ReadObserver<ReflectLookups>()
  private let kinds: Set<HistoryKind>?
  var search: String

  init(context: MemoirScreenContext, id: String, kind: HistoryKind? = nil, search: String = "", bodyClasses: Set<SyncClass> = ReflectBody.onThisDevice) {
    self.context = context
    self.id = id
    self.bodyClasses = bodyClasses
    kinds = kind.map { [$0] }
    self.search = search
    day = ReflectDayFollower(context: context)
  }

  var presentation: HistoryRecordState {
    switch history.state {
    case .loading: return .loading
    case .failed(let error): return .failed(error)
    case .loaded(let page):
      guard let record = page.records.items.first(where: { $0.id == id }) else { return .missing }
      return .found(HistoryPresentation(record, day: day.day, lookups: lookups.state.value, home: page.totals.spent?.home))
    }
  }

  func followToday() async {
    await day.follow()
  }

  func observe() async {
    guard let today = day.day?.today else { return }
    let stores = context.stores
    let query = HistoryQuery(kinds: kinds, search: search, categoryNames: ReflectCopy.builtInCategoryNames, page: .all)
    let bodyClasses = bodyClasses
    await history.run { ReflectReads.observeHistory(in: stores, matching: query, bodyClasses: bodyClasses, today: today) }
  }

  func observeLookups() async {
    let main = context.stores.main
    await lookups.run { main.observe(ReflectLookups.self, ReflectLookupsQuery(streaks: false)) }
  }
}

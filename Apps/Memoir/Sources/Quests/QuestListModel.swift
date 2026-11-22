import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// The list read twice in one transaction: every quest, which says whether there are any and how many the filter holds, and the ones the filter and
/// search keep, as the core matches them.
nonisolated struct QuestListing: ReplayReadModel {
  let all: QuestList
  let shown: QuestList

  static func load(_ query: QuestListQuery, in transaction: ReadTransaction) throws(StoreError) -> QuestListing {
    let all = try QuestList.load(QuestListQuery(filter: .all), in: transaction)
    let isEverything = query.filter == .all && query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return QuestListing(all: all, shown: isEverything ? all : try QuestList.load(query, in: transaction))
  }

  var isSearching: Bool { !shown.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// How many quests the filter holds before the search narrows it (`filterNote`, `quest-list-screen.tsx:30-36`).
  var inFilter: Int {
    switch shown.filter {
    case .active: all.entries.count { $0.quest.isActive }
    case .inactive: all.entries.count { !$0.quest.isActive }
    case .all: all.entries.count
    }
  }
}

@MainActor
@Observable
final class QuestListModel {
  private let context: MemoirScreenContext
  let listing = ReadObserver<QuestListing>()
  var filter = QuestFilter.active
  var search = ""

  init(context: MemoirScreenContext) {
    self.context = context
  }

  var query: QuestListQuery { QuestListQuery(filter: filter, search: search) }

  func observe() async {
    let query = query
    let main = context.stores.main
    await listing.run { main.observe(QuestListing.self, query) }
  }
}

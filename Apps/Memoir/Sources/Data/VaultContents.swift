import Foundation
import MemoirCore
import ShadowCore
import ShadowStore

/// The sets the export and deletion screens list (`projectRecordCounts`, `lib/sync/projection.ts:762-773`), counted from the records of all three
/// stores; a removed record is not counted. The hero's level, titles and achievements are worked out from the history, so they have no count of
/// their own.
nonisolated struct VaultContents: Equatable, Sendable {
  enum Item: CaseIterable, Sendable {
    case quests, actions, expenses, subscriptions, receipts, journalEntries, weights, meals, sideQuests, metricDays, coachingResults

    var kinds: [MemoirKind] {
      switch self {
      case .quests: [.quest]
      case .actions: [.command]
      case .expenses: [.expense]
      case .subscriptions: [.subscription]
      case .receipts: [.receipt]
      case .journalEntries: [.journalEntry]
      case .weights: [.weight]
      case .meals: [.meal]
      case .sideQuests: [.sideQuest]
      case .metricDays: [.generalMetricDay, .activityMetricDay, .healthMetricDay]
      case .coachingResults: [.generalInsight, .activityInsight, .healthInsight]
      }
    }
  }

  enum Area: CaseIterable, Sendable {
    case questsAndHistory, money, journal, bodyAndHealth, coaching

    var items: [Item] {
      switch self {
      case .questsAndHistory: [.quests, .actions]
      case .money: [.expenses, .subscriptions, .receipts]
      case .journal: [.journalEntries]
      case .bodyAndHealth: [.weights, .meals, .sideQuests, .metricDays]
      case .coaching: [.coachingResults]
      }
    }
  }

  enum Load: Equatable, Sendable {
    case loading
    case loaded(VaultContents)
    case failed
  }

  let counts: [MemoirKind: Int]

  func count(_ item: Item) -> Int {
    item.kinds.reduce(0) { $0 + (counts[$1] ?? 0) }
  }

  static func read(_ stores: MemoirStores) async throws(StoreError) -> VaultContents {
    var counts = [MemoirKind: Int]()
    for store in MemoirStoreKind.allCases {
      let kinds = MemoirSchema.entities(of: store).compactMap { MemoirKind($0.kind) }
      let counted = try await stores.store(store).read { transaction in
        try kinds.map { kind in (kind, try transaction.states(ofKind: kind.entityKind, scope: .vault).count { isLive($0.state) }) }
      }
      for (kind, count) in counted { counts[kind] = count }
    }
    return VaultContents(counts: counts)
  }

  private static func isLive(_ state: EntityState) -> Bool {
    switch state {
    case .purged: false
    case .appended: true
    case .record(let record): record[field: "removed"]?.value.boolValue != true
    case .revisioned(let document): document[field: "removed"]?.value.boolValue != true
    }
  }
}

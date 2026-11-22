import Foundation
import ShadowStore

/// The Log screens' read models. Journal, meals and side quests are general class and come from the main store; weight from the restricted store; each
/// metric from the store of its class. Nothing here writes.
public enum LogReads {
  public static func journal(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> JournalOverview {
    try await readMain(stores) { transaction in try journal(in: transaction, today: today) }
  }

  public static func observeJournal(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<JournalOverview, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try journal(in: transaction, today: today) }) { $0 }
  }

  public static func meals(in stores: MemoirStores, on date: LocalDate, today: LocalDate) async throws(MemoirReadError) -> MealsOverview {
    try await readMain(stores) { transaction in try meals(in: transaction, on: date, today: today) }
  }

  public static func observeMeals(in stores: MemoirStores, on date: LocalDate, today: LocalDate) -> AsyncThrowingStream<MealsOverview, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try meals(in: transaction, on: date, today: today) }) { $0 }
  }

  public static func sideQuests(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> SideQuestsOverview {
    try await readMain(stores) { transaction in try sideQuests(in: transaction, today: today) }
  }

  public static func observeSideQuests(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<SideQuestsOverview, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try sideQuests(in: transaction, today: today) }) { $0 }
  }

  /// Health class, read from the restricted store only.
  public static func weight(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> WeightOverview {
    try await readCall { () async throws(StoreError) in try await stores.restricted.read { transaction in try weight(in: transaction, today: today) } }
  }

  public static func observeWeight(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<WeightOverview, any Error> {
    ReadObservation.observe(ObservedRead(stores.restricted) { transaction in try weight(in: transaction, today: today) }) { $0 }
  }

  /// The metrics of `classes`, each read in its own store; `activeQuests` (replay's, from the quest read model) are the quests a threshold may offer.
  public static func metrics(
    in stores: MemoirStores, classes: Set<SyncClass>, activeQuests: [UUID], today: LocalDate, days: Int = MetricsOverview.trendDays
  ) async throws(MemoirReadError) -> MetricsOverview {
    guard let window = DateSpan.trailing(days, endingOn: today) else { throw .finance(.dateOutOfRange) }
    let quests = try await readMain(stores) { transaction in try MetricQuestContext.load(window: window, in: transaction) }
    var snapshots = [MetricClassSnapshot]()
    for syncClass in SyncClass.allCases where classes.contains(syncClass) {
      snapshots.append(try await readCall { () async throws(StoreError) in try await stores.store(of: syncClass).read { try MetricClassSnapshot.load(syncClass, in: $0) } })
    }
    return MetricsOverview.make(snapshots, quests: quests, activeQuests: activeQuests, window: window, today: today)
  }

  public static func observeMetrics(
    in stores: MemoirStores, classes: Set<SyncClass>, activeQuests: [UUID], today: LocalDate, days: Int = MetricsOverview.trendDays
  ) -> AsyncThrowingStream<MetricsOverview, any Error> {
    guard let window = DateSpan.trailing(days, endingOn: today) else {
      return AsyncThrowingStream { $0.finish(throwing: MemoirReadError.finance(.dateOutOfRange)) }
    }
    let main = ObservedRead(stores.main) { transaction in
      Pair(
        quests: try MetricQuestContext.load(window: window, in: transaction),
        snapshot: classes.contains(.general) ? try MetricClassSnapshot.load(.general, in: transaction) : nil)
    }
    let build = { @Sendable (main: Pair, others: [MetricClassSnapshot?]) in
      MetricsOverview.make([main.snapshot].compactMap { $0 } + others.compactMap { $0 }, quests: main.quests, activeQuests: activeQuests, window: window, today: today)
    }
    let activity = classes.contains(.activity) ? snapshot(.activity, in: stores) : nil
    let restricted = classes.contains(.health) ? snapshot(.health, in: stores) : nil
    switch (activity, restricted) {
    case (let activity?, let restricted?): return ReadObservation.observe(main, activity, restricted) { build($0, [$1, $2]) }
    case (let only?, nil), (nil, let only?): return ReadObservation.observe(main, only) { build($0, [$1]) }
    case (nil, nil): return ReadObservation.observe(main) { build($0, []) }
    }
  }

  /// `includeHealth` adds the weight count, read from the restricted store.
  public static func entryCaps(in stores: MemoirStores, today: LocalDate, includeHealth: Bool) async throws(MemoirReadError) -> EntryCapsOverview {
    guard let month = DateSpan.month(of: today) else { throw .finance(.dateOutOfRange) }
    let general = try await readMain(stores) { transaction in try generalCounts(in: transaction, month: month) }
    let weights = includeHealth ? try await readCall { () async throws(StoreError) in try await stores.restricted.read { try weightCount(in: $0, month: month) } } : nil
    return entryCaps(month: month, general: general, weights: weights)
  }

  public static func observeEntryCaps(in stores: MemoirStores, today: LocalDate, includeHealth: Bool) -> AsyncThrowingStream<EntryCapsOverview, any Error> {
    guard let month = DateSpan.month(of: today) else { return AsyncThrowingStream { $0.finish(throwing: MemoirReadError.finance(.dateOutOfRange)) } }
    let general = ObservedRead(stores.main) { transaction in try generalCounts(in: transaction, month: month) }
    guard includeHealth else { return ReadObservation.observe(general) { entryCaps(month: month, general: $0, weights: nil) } }
    return ReadObservation.observe(general, ObservedRead(stores.restricted) { try weightCount(in: $0, month: month) }) {
      entryCaps(month: month, general: $0, weights: $1)
    }
  }

  private struct Pair: Sendable, Equatable {
    let quests: MetricQuestContext
    let snapshot: MetricClassSnapshot?
  }

  private static func snapshot(_ syncClass: SyncClass, in stores: MemoirStores) -> ObservedRead<MetricClassSnapshot?> {
    ObservedRead(stores.store(of: syncClass)) { transaction in try MetricClassSnapshot.load(syncClass, in: transaction) }
  }

  static func journal(in transaction: ReadTransaction, today: LocalDate) throws(StoreError) -> JournalOverview {
    let journal = try ReadSources.listing(JournalEntryRecord.self, in: transaction)
    return JournalOverview.make(journal.records, unreadable: journal.unreadable, today: today)
  }

  static func meals(in transaction: ReadTransaction, on date: LocalDate, today: LocalDate) throws(StoreError) -> MealsOverview {
    let meals = try ReadSources.listing(MealRecord.self, in: transaction)
    let presets = try ReadSources.listing(MealPresetRecord.self, in: transaction)
    return MealsOverview.make(meals: meals.records, presets: presets.records, unreadable: meals.unreadable + presets.unreadable, date: date, today: today)
  }

  static func sideQuests(in transaction: ReadTransaction, today: LocalDate) throws(StoreError) -> SideQuestsOverview {
    let sideQuests = try ReadSources.listing(SideQuestRecord.self, in: transaction)
    return SideQuestsOverview.make(sideQuests.records, outcomes: try SideQuestOutcomes.load(in: transaction), unreadable: sideQuests.unreadable, today: today)
  }

  static func weight(in transaction: ReadTransaction, today: LocalDate) throws(StoreError) -> WeightOverview {
    let weights = try ReadSources.listing(WeightRecord.self, in: transaction)
    return WeightOverview.make(weights.records, unreadable: weights.unreadable, today: today)
  }

  private static func generalCounts(in transaction: ReadTransaction, month: DateSpan) throws(StoreError) -> [LoggableModule: Int] {
    [
      .expenses: try ReadSources.listing(ExpenseRecord.self, in: transaction).records.count { month.contains($0.occurredOn) },
      .journal: try ReadSources.listing(JournalEntryRecord.self, in: transaction).records.count { month.contains($0.date) },
      .meals: try ReadSources.listing(MealRecord.self, in: transaction).records.count { month.contains($0.date) },
      .sideQuests: try ReadSources.listing(SideQuestRecord.self, in: transaction).records.count { month.contains($0.date) },
    ]
  }

  private static func weightCount(in transaction: ReadTransaction, month: DateSpan) throws(StoreError) -> Int {
    try ReadSources.listing(WeightRecord.self, in: transaction).records.count { month.contains($0.date) }
  }

  private static func entryCaps(month: DateSpan, general: [LoggableModule: Int], weights: Int?) -> EntryCapsOverview {
    let advisories = LoggableModule.allCases.compactMap { module -> EntryCapAdvisory? in
      guard let used = module == .weight ? weights : general[module] else { return nil }
      return EntryCapAdvisory(module: module, used: used)
    }
    return EntryCapsOverview(month: month, classes: weights == nil ? [.general] : [.general, .health], advisories: advisories)
  }

  private static func readMain<Value: Sendable>(_ stores: MemoirStores, _ body: @escaping @Sendable (ReadTransaction) throws -> Value) async throws(MemoirReadError)
    -> Value
  {
    try await readCall { () async throws(StoreError) in try await stores.main.read(body) }
  }
}

import Foundation
import ShadowStore

/// What the Reflect surfaces read from the main store: replay's quest logs, unlocks and hero, and the general-class records.
struct ReflectGeneral: Sendable, Equatable {
  let logs: [QuestLogRow]
  let questNames: [UUID: String]
  let book: MoneyBook
  let journal: [JournalEntryRecord]
  let meals: [MealRecord]
  let sideQuests: [SideQuestRecord]
  let sideQuestOutcomes: SideQuestOutcomes
  let unlocks: [UnlockRow]
  let hero: HeroSummaryRow?
  let today: DayRow?
  let unreadable: Int

  static func load(today: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> ReflectGeneral {
    let book: MoneyBook
    do throws(MemoirReadError) {
      book = try MoneyBook.load(from: transaction)
    } catch {
      throw .aborted(error)
    }
    let journal = try ReadSources.listing(JournalEntryRecord.self, in: transaction)
    let meals = try ReadSources.listing(MealRecord.self, in: transaction)
    let sideQuests = try ReadSources.listing(SideQuestRecord.self, in: transaction)
    return ReflectGeneral(
      logs: try ReadSources.allQuestLogs(in: transaction), questNames: try ReadSources.questNames(in: transaction), book: book, journal: journal.records,
      meals: meals.records, sideQuests: sideQuests.records, sideQuestOutcomes: try SideQuestOutcomes.load(in: transaction),
      unlocks: try MemoirDerived.unlocks(in: transaction), hero: try MemoirDerived.hero(in: transaction),
      today: try MemoirDerived.days(from: today, through: today, in: transaction).first,
      unreadable: book.unreadable + journal.unreadable + meals.unreadable + sideQuests.unreadable)
  }

  func logs(in span: DateSpan) -> [QuestLogRow] {
    logs.filter { span.contains($0.occurrence.date) }
  }

  func xp(in span: DateSpan) -> Int {
    Exact.adding(Exact.sum(logs(in: span).map(\.entry.xpAwarded)), sideQuestOutcomes.xp(in: span))
  }
}

/// What the Reflect surfaces read from the activity and restricted stores, each only when its class was asked for.
struct ReflectBodySource: Sendable, Equatable {
  let classes: Set<SyncClass>
  let weights: [WeightRecord]
  let metrics: [MetricClassSnapshot]
  let unreadable: Int

  static let none = ReflectBodySource(classes: [], weights: [], metrics: [], unreadable: 0)

  static func activity(in transaction: ReadTransaction) throws(StoreError) -> ReflectBodySource {
    let snapshot = try MetricClassSnapshot.load(.activity, in: transaction)
    return ReflectBodySource(classes: [.activity], weights: [], metrics: [snapshot], unreadable: snapshot.unreadable)
  }

  static func health(in transaction: ReadTransaction) throws(StoreError) -> ReflectBodySource {
    let snapshot = try MetricClassSnapshot.load(.health, in: transaction)
    let weights = try ReadSources.listing(WeightRecord.self, in: transaction)
    return ReflectBodySource(classes: [.health], weights: weights.records, metrics: [snapshot], unreadable: snapshot.unreadable + weights.unreadable)
  }

  func merged(with other: ReflectBodySource) -> ReflectBodySource {
    ReflectBodySource(
      classes: classes.union(other.classes), weights: weights + other.weights, metrics: metrics + other.metrics, unreadable: unreadable + other.unreadable)
  }
}

/// memoir-web `HOLD_WEIGHT` and `CARRIED_STATES` (`lib/data/reflect.derive.ts:125-140`): a partial holds half an occurrence, and a postponed or rescheduled
/// one resolves where it moved to, so it is not counted where it was planned.
public struct Adherence: Sendable, Hashable {
  public static let empty = Adherence(heldHalves: 0, occurrences: 0)

  public let heldHalves: Int
  public let occurrences: Int

  init(heldHalves: Int, occurrences: Int) {
    self.heldHalves = heldHalves
    self.occurrences = occurrences
  }

  init(_ logs: some Sequence<QuestLogRow>) {
    let counted = logs.filter { !Self.isCarried($0.entry.state) }
    self.init(heldHalves: Exact.sum(counted.map { Self.heldHalves($0.entry.state) }), occurrences: counted.count)
  }

  public var held: Halves { Halves(heldHalves) }
  /// `nil` with no occurrence counted.
  public var ratio: Fraction? { occurrences > 0 ? Fraction(numerator: heldHalves, denominator: 2 * occurrences) : nil }
  public var percent: Int? { ratio?.percent }

  public static func heldHalves(_ state: QuestLogState) -> Int {
    switch state {
    case .completed, .late, .recovery: 2
    case .partial: 1
    case .skipped, .missed, .postponed, .rescheduled: 0
    }
  }

  public static func isCarried(_ state: QuestLogState) -> Bool {
    state == .postponed || state == .rescheduled
  }

  public static func holds(_ state: QuestLogState) -> Bool {
    heldHalves(state) > 0
  }
}

public struct ReasonCount: Sendable, Hashable {
  public let reason: ReasonTag
  public let count: Int

  /// memoir-web `reasonBars` (`reflect.derive.ts:640-651`): the reasons given, most frequent first, ties in the order first given, at most six.
  static func ranked(_ logs: [QuestLogRow], limit: Int = 6) -> [ReasonCount] {
    var order = [ReasonTag]()
    var counts = [ReasonTag: Int]()
    for log in logs {
      guard let reason = log.entry.reasonTag else { continue }
      if counts[reason] == nil { order.append(reason) }
      counts[reason, default: 0] += 1
    }
    return order.enumerated().sorted { first, second in
      let left = counts[first.element] ?? 0
      let right = counts[second.element] ?? 0
      return left != right ? left > right : first.offset < second.offset
    }.prefix(limit).map { ReasonCount(reason: $0.element, count: counts[$0.element] ?? 0) }
  }
}

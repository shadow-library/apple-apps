import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// The account's day and zone: Reflect's reads follow a day turn, and a record's time is shown in the clock that was in force when it was logged.
nonisolated struct ReflectDay: Sendable, Equatable {
  let today: LocalDate
  let zone: AccountZone
  let deviceZone: TimeZone

  func time(atMillis millis: Int64) -> String {
    ReflectFormat.time(millis: millis, in: zone.clock(at: millis, device: deviceZone).timeZone)
  }

  static func observe(_ context: MemoirScreenContext) -> AsyncThrowingStream<ReflectDay, any Error> {
    let clock = context.clock
    return context.stores.main.observeReads { transaction in
      let zone = try AccountZone.load(in: transaction)
      return ReflectDay(today: try clock.today(in: zone).date, zone: zone, deviceZone: clock.deviceZone())
    }
  }
}

/// The body classes Reflect reads. Every device opens its activity and health stores, so both are read here: a store holds what this device recorded
/// and what its storage syncs to it, never anything another device keeps to itself.
nonisolated enum ReflectBody {
  static let onThisDevice: Set<SyncClass> = [.activity, .health]
}

@MainActor
@Observable
final class ReflectDayFollower {
  private let context: MemoirScreenContext
  private(set) var day: ReflectDay?
  private(set) var failure: PresentedError?

  init(context: MemoirScreenContext) {
    self.context = context
  }

  func follow() async {
    failure = nil
    do {
      for try await day in ReflectDay.observe(context) where day != self.day {
        self.day = day
      }
    } catch is CancellationError {
      return
    } catch {
      failure = WritingErrors.presented(error) ?? PresentedError(error)
    }
  }
}

nonisolated struct ReflectLookupsQuery: Sendable, Hashable {
  let streaks: Bool
}

nonisolated struct LongestStreak: Sendable, Equatable {
  let quest: UUID
  let name: String?
  let days: Int
}

/// The names the Reflect reads leave as keys: category labels the owner gave, subscription names, and with `streaks` the longest run any quest has
/// reached, as the reference's Insights reads it from every quest's best run (`reflect.derive.ts:511-541`).
nonisolated struct ReflectLookups: ReplayReadModel {
  let categoryLabels: [CategoryKey: String]
  let subscriptionNames: [UUID: String]
  let longestStreak: LongestStreak?

  static func load(_ query: ReflectLookupsQuery, in transaction: ReadTransaction) throws(StoreError) -> ReflectLookups {
    let categories = try ExpenseCategoryRecord.listing(in: transaction).entries.map(\.record)
    let subscriptions = try SubscriptionRecord.listing(in: transaction).entries.map(\.record)
    let streak = query.streaks ? longest(try QuestList.load(QuestListQuery(filter: .all), in: transaction)) : nil
    return ReflectLookups(
      categoryLabels: Dictionary(categories.map { ($0.categoryKey, $0.label) }) { first, _ in first },
      subscriptionNames: Dictionary(subscriptions.map { ($0.id, $0.name) }) { first, _ in first }, longestStreak: streak)
  }

  /// The first quest with the longest best run, as the reference's stable sort keeps it.
  private static func longest(_ list: QuestList) -> LongestStreak? {
    var best: QuestSummary?
    for entry in list.entries where entry.streak.longestDays > (best?.streak.longestDays ?? 0) {
      best = entry
    }
    return best.map { LongestStreak(quest: $0.id, name: $0.quest.name, days: $0.streak.longestDays) }
  }

  func category(_ key: CategoryKey) -> String {
    ReflectCopy.builtInCategory(key) ?? categoryLabels[key] ?? key.key
  }
}

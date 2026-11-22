import Foundation
import ShadowStore

public struct JournalEntrySummary: Sendable, Equatable {
  public let entry: JournalEntryRecord
  public let wordCount: Int
  public let excerpt: String

  init(_ entry: JournalEntryRecord) {
    self.entry = entry
    wordCount = JournalText.wordCount(entry.text)
    excerpt = JournalText.excerpt(entry.text)
  }
}

/// An earlier entry written on today's month and day.
public struct OnThisDay: Sendable, Equatable {
  public static let excerptLength = 140

  public let year: Int
  public let entry: UUID
  public let excerpt: String
}

/// memoir-web `SyncedQuickLogProvider.journal` (`lib/sync/synced-quick-log-provider.ts:181-196`).
public struct JournalOverview: Sendable, Equatable {
  public static let trendDays = 28

  public let today: JournalEntrySummary?
  /// Newest first by date, then by when it was logged.
  public let entries: [JournalEntrySummary]
  /// Days in a row up to today with an entry; zero when today has none.
  public let writingStreakDays: Int
  /// The words written on each of the last 28 days, oldest first.
  public let words: [DayValue<Int>]
  public let moods: [DayValue<Int>]
  public let onThisDay: OnThisDay?
  public let unreadable: Int

  static func make(_ entries: [JournalEntryRecord], unreadable: Int, today: LocalDate) -> JournalOverview {
    let summaries = entries.sorted { ($0.date, $0.loggedAtMillis, $0.id.uuidString) > ($1.date, $1.loggedAtMillis, $1.id.uuidString) }.map(JournalEntrySummary.init)
    var byDate = [LocalDate: JournalEntrySummary]()
    for summary in summaries where byDate[summary.entry.date] == nil { byDate[summary.entry.date] = summary }
    var streak = 0
    while let day = today.adding(days: -streak), byDate[day] != nil { streak += 1 }
    let window = DateSpan.trailing(trendDays, endingOn: today)?.dates ?? []
    let earlier = summaries.first { $0.entry.date < today && $0.entry.date.month == today.month && $0.entry.date.day == today.day }
    return JournalOverview(
      today: byDate[today], entries: summaries, writingStreakDays: streak, words: window.map { DayValue(date: $0, value: byDate[$0]?.wordCount) },
      moods: window.map { DayValue(date: $0, value: byDate[$0]?.entry.mood) },
      onThisDay: earlier.map {
        OnThisDay(year: $0.entry.date.year, entry: $0.entry.id, excerpt: JournalText.excerpt($0.entry.text, maxLength: OnThisDay.excerptLength))
      }, unreadable: unreadable)
  }
}

/// memoir-web `SyncedQuickLogProvider.meals` (`synced-quick-log-provider.ts:223-253`).
public struct MealsOverview: Sendable, Equatable {
  public static let trendDays = 14

  public struct PresetUsage: Sendable, Equatable {
    public let preset: MealPresetRecord
    public let usageCount: Int
  }

  public let date: LocalDate
  /// The day's meals in the order they were logged.
  public let meals: [MealRecord]
  public let totalCalories: Int
  /// Each of the last 14 days' calories, oldest first; `nil` on a day with no meal.
  public let calories: [DayValue<Int>]
  /// The mean over the days with a meal, halves up; `nil` when none has one.
  public let averageCalories: Int?
  /// Most used first, then by name.
  public let presets: [PresetUsage]
  public let unreadable: Int

  static func make(meals: [MealRecord], presets: [MealPresetRecord], unreadable: Int, date: LocalDate, today: LocalDate) -> MealsOverview {
    let byDate = Dictionary(grouping: meals, by: \.date)
    let window = DateSpan.trailing(trendDays, endingOn: today)?.dates ?? []
    let calories = window.map { day in DayValue(date: day, value: byDate[day].map { Exact.sum($0.map(\.calories)) }) }
    let logged = calories.compactMap(\.value)
    let average = logged.isEmpty ? nil : Int(clamping: Exact.roundHalfUp(Int128(Exact.sum(logged)), Int128(logged.count)))
    let uses = Dictionary(grouping: meals.compactMap(\.preset), by: { $0 }).mapValues(\.count)
    let usage = presets.map { PresetUsage(preset: $0, usageCount: uses[$0.id] ?? 0) }.sorted { first, second in
      first.usageCount != second.usageCount ? first.usageCount > second.usageCount : first.preset.name < second.preset.name
    }
    let onDate = (byDate[date] ?? []).sorted { ($0.loggedAtMillis, $0.id.uuidString) < ($1.loggedAtMillis, $1.id.uuidString) }
    return MealsOverview(
      date: date, meals: onDate, totalCalories: Exact.sum(onDate.map(\.calories)), calories: calories, averageCalories: average, presets: usage, unreadable: unreadable)
  }
}

/// memoir-web side quests (`synced-quick-log-provider.ts:315-329`): only the first three a day carry the reward (`quick-logs.rules.ts:102,192-197`).
public struct SideQuestsOverview: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let sideQuest: SideQuestRecord
    public let rewarded: Bool
  }

  /// Newest first by when it was logged.
  public let items: [Item]
  public let loggedThisWeek: Int
  public let loggedThisMonth: Int
  public let xpThisMonth: Int
  public let rewardedToday: Int
  public let rewardLimit: Int
  public let unreadable: Int

  public var remainingRewardsToday: Int { max(0, rewardLimit - rewardedToday) }
  public var isRewardCapReached: Bool { rewardedToday >= rewardLimit }

  static func make(_ sideQuests: [SideQuestRecord], rewards: SideQuestRewards, unreadable: Int, today: LocalDate) -> SideQuestsOverview {
    let items = sideQuests.sorted { ($0.loggedAtMillis, $0.id.uuidString) > ($1.loggedAtMillis, $1.id.uuidString) }.map {
      Item(sideQuest: $0, rewarded: rewards.grants[$0.id] != nil)
    }
    let weekStart = today.adding(days: -7) ?? today
    let month = DateSpan.month(of: today)
    let thisMonth = items.filter { month?.contains($0.sideQuest.date) ?? false }
    return SideQuestsOverview(
      items: items, loggedThisWeek: items.count { $0.sideQuest.date >= weekStart }, loggedThisMonth: thisMonth.count,
      xpThisMonth: Exact.sum(thisMonth.compactMap { rewards.grants[$0.sideQuest.id]?.xp }), rewardedToday: rewards.rewardedPerDay[today] ?? 0,
      rewardLimit: Ruleset.current.quickLogs[.sideQuest].maxRewardedPerDay, unreadable: unreadable)
  }
}

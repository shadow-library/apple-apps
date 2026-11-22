import Foundation
import ShadowStore

public struct HeroDeckQuery: Sendable, Hashable {
  /// `EVENT_LIMIT` (`lib/sync/synced-hero-provider.ts:47`).
  public static let defaultEventLimit = 8

  public let eventLimit: Int

  public init(eventLimit: Int = defaultEventLimit) {
    self.eventLimit = eventLimit
  }
}

/// What the hero is called (`lib/data/hero.provider.ts:36-39`): the displayed title, else a prompt to choose one once any is earned.
public enum HeroName: Sendable, Hashable {
  case title(TitleID)
  case chooseTitle
  case untitled
}

/// One stat with its share of the hero's best stat, rounded half up (`synced-hero-provider.ts:170-180`).
public struct LifetimeStat: Sendable, Hashable {
  /// `STAT_ORDER` (`synced-hero-provider.ts:52`).
  public static let order: [StatAffinity] = [.body, .mind, .wealth, .discipline]

  public let stat: StatAffinity
  public let value: Int
  public let percentOfBest: Int
}

/// A hero trail entry as the deck lists it, with the name of the quest it came from.
public struct ProgressionEntry: Sendable, Hashable, Identifiable {
  public let ordinal: Int
  public let event: HeroEvent
  public let questName: String?

  public var id: Int { ordinal }
  public var isRewarded: Bool { event.xpDelta > 0 || event.coinsDelta > 0 }
}

/// A closed Crown period (`lib/sync/projection.ts:956-961`): banked when anything of it was left to bank.
public struct CrownClose: Sendable, Hashable, Identifiable {
  public static let historyLength = 7

  public let periodStart: LocalDate
  public let closedOn: LocalDate
  public let banked: RewardAmount

  public var isBanked: Bool { banked.xp + banked.coins > 0 }
  public var id: LocalDate { closedOn }
}

public struct AchievementStanding: Sendable, Hashable, Identifiable {
  public let id: AchievementID
  public let earnedOn: LocalDate?
  /// The cosmetic it unlocks, which coins cannot buy.
  public let unlocks: CosmeticID?
}

public struct TitleStanding: Sendable, Hashable, Identifiable {
  public let id: TitleID
  public let earnedOn: LocalDate?
  public let isDisplayed: Bool
}

/// `cosmeticsFor` (`synced-hero-provider.ts:141-153`): equipped, owned, affordable, short of coins by an amount, or only an achievement's.
public enum CosmeticState: Sendable, Hashable {
  case equipped(CosmeticSource)
  case owned(CosmeticSource)
  case affordable
  case short(by: Int)
  case achievementOnly(AchievementID?)
}

public struct CosmeticStanding: Sendable, Hashable, Identifiable {
  public let id: CosmeticID
  public let kind: CosmeticID.Kind
  public let priceCoins: Int?
  public let state: CosmeticState
}

/// The Hero screen: level, coins, HP, stats, recent progression, the Crown and its history, momentum, shields, and the catalogues of achievements,
/// titles and cosmetics from the rules (`Rules/Progress.swift`, `CosmeticID`); their names and descriptions are the app's strings.
public struct HeroDeck: ReplayReadModel {
  public let name: HeroName
  public let level: LevelProgress
  public let coins: Int
  public let hp: DayHP?
  public let stats: [LifetimeStat]
  public let progression: [ProgressionEntry]
  public let crown: CrownWindow?
  /// Oldest first.
  public let crownHistory: [CrownClose]
  public let momentum: MomentumBucket?
  public let comingBack: ComingBackReason?
  public let shields: ShieldStanding
  public let activeDays: Int
  public let questsCompleted: Int
  public let longestStreakDays: Int
  public let achievements: [AchievementStanding]
  public let titles: [TitleStanding]
  public let cosmetics: [CosmeticStanding]
  public let notices: [ReplayNotice]
  public let halt: ReplayHalt?
  public let changesOn: LocalDate?

  public var achievementsEarned: Int { achievements.count { $0.earnedOn != nil } }

  public static func load(_ query: HeroDeckQuery, in transaction: ReadTransaction) throws(StoreError) -> HeroDeck {
    let context = try QuestReadContext.load(in: transaction)
    let ruleset = context.ruleset
    let hero = context.hero
    let unlocks = try MemoirDerived.unlocks(in: transaction)
    let achievementDays = Dictionary(unlocks.filter { $0.kind == .achievement }.compactMap { row in AchievementID(rawValue: row.id).map { ($0, row.unlockedOn) } }) { $1 }
    let titleDays = Dictionary(unlocks.filter { $0.kind == .title }.compactMap { row in TitleID(rawValue: row.id).map { ($0, row.unlockedOn) } }) { $1 }
    let owned = Dictionary(unlocks.filter { $0.kind == .cosmetic }.compactMap { row in CosmeticID(rawValue: row.id).map { ($0, row) } }) { $1 }
    let displayed = hero?.displayedTitle
    let coins = hero?.coins ?? 0
    let openDay = context.openDay
    let recovery = try openDay.flatMap { day throws(StoreError) in try MemoirDerived.recoveries(from: day, through: day, in: transaction).first }
    return HeroDeck(
      name: name(displayed: displayed, anyEarned: !titleDays.isEmpty),
      level: LevelProgress(level: hero?.level ?? 1, totalXP: hero?.totalXP ?? 0, ruleset: ruleset), coins: coins, hp: context.openDayRow?.hp,
      stats: stats(hero?.stats ?? RuleTable { _ in 0 }),
      progression: try MemoirDerived.recentHeroEvents(in: transaction).prefix(max(0, query.eventLimit))
        .map { ProgressionEntry(ordinal: $0.ordinal, event: $0.event, questName: $0.event.quest.flatMap { context.records[$0]?.name }) },
      crown: try openDay.flatMap { day throws(StoreError) in try CrownWindow.load(containing: day, row: context.openDayRow, ruleset: ruleset, in: transaction) },
      crownHistory: try MemoirDerived.crownCloses(limit: CrownClose.historyLength, in: transaction).reversed().compactMap { row in
        row.crownBanked.map { CrownClose(periodStart: row.crownPeriodStart ?? row.date, closedOn: row.date, banked: $0) }
      },
      momentum: context.openDayRow?.momentum, comingBack: ComingBackReason.on(context.openDayRow, recovery: recovery),
      shields: ShieldStanding(context.quests, ruleset: ruleset), activeDays: hero?.activeDays ?? 0, questsCompleted: hero?.questsCompleted ?? 0,
      longestStreakDays: hero?.longestStreakDays ?? 0,
      achievements: AchievementID.allCases.map { id in
        AchievementStanding(id: id, earnedOn: achievementDays[id] ?? nil, unlocks: CosmeticID.allCases.first { $0.unlockedBy == id })
      },
      titles: TitleID.allCases.map { TitleStanding(id: $0, earnedOn: titleDays[$0] ?? nil, isDisplayed: $0 == displayed) },
      cosmetics: CosmeticID.allCases.map { cosmetic in
        CosmeticStanding(id: cosmetic, kind: cosmetic.kind, priceCoins: cosmetic.priceCoins, state: state(of: cosmetic, owned: owned[cosmetic], coins: coins))
      },
      notices: try MemoirDerived.notices(in: transaction).map(\.notice), halt: hero?.halt, changesOn: context.changesOn)
  }

  static func stats(_ table: RuleTable<StatAffinity, Int>) -> [LifetimeStat] {
    let best = LifetimeStat.order.map { table[$0] }.max() ?? 0
    return LifetimeStat.order.map { stat in
      LifetimeStat(stat: stat, value: table[stat], percentOfBest: best <= 0 ? 0 : Int(clamping: Exact.roundHalfUp(Int128(table[stat]) * 100, Int128(best))))
    }
  }

  static func name(displayed: TitleID?, anyEarned: Bool) -> HeroName {
    displayed.map(HeroName.title) ?? (anyEarned ? .chooseTitle : .untitled)
  }

  static func state(of cosmetic: CosmeticID, owned: UnlockRow?, coins: Int) -> CosmeticState {
    if let owned {
      let source = owned.source ?? .coin
      return owned.equipped ? .equipped(source) : .owned(source)
    }
    guard let price = cosmetic.priceCoins else { return .achievementOnly(cosmetic.unlockedBy) }
    return coins >= price ? .affordable : .short(by: price - coins)
  }
}

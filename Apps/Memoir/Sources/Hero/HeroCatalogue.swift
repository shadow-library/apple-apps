import Foundation
import MemoirCore

/// The words and symbols for the core's catalogues (`hero.provider.ts:83-271`), which hold only ids and rules; `HeroCopyTests` checks each id's words
/// are in `Hero.xcstrings`.
nonisolated enum HeroCatalogue {
  static func name(of achievement: AchievementID) -> String {
    switch achievement {
    case .firstQuestCompleted: String(localized: "First Promise", table: "Hero")
    case .firstLevelUp: String(localized: "Second Level", table: "Hero")
    case .firstBronzeStreak: String(localized: "Three Days", table: "Hero")
    case .firstSilverStreak: String(localized: "Seven Days", table: "Hero")
    case .firstGoldStreak: String(localized: "Thirty Mornings", table: "Hero")
    case .firstPlatinumStreak: String(localized: "A Hundred Days", table: "Hero")
    case .xp100: String(localized: "First Hundred", table: "Hero")
    case .xp500: String(localized: "Five Hundred", table: "Hero")
    case .firstSubscriptionConfirmed: String(localized: "Named the Recurring", table: "Hero")
    case .firstReceiptScanned: String(localized: "Honest Ledger", table: "Hero")
    case .allStatsTouched: String(localized: "Four Directions", table: "Hero")
    case .firstFullHPDay: String(localized: "Whole Day", table: "Hero")
    case .firstCrownBanked: String(localized: "First Crown", table: "Hero")
    case .firstRecoveryCompleted: String(localized: "Lighter Version", table: "Hero")
    case .firstLockedDayCleared: String(localized: "Committed", table: "Hero")
    case .firstComebackClaimed: String(localized: "Comeback", table: "Hero")
    case .firstReturnerRitual: String(localized: "The Returner", table: "Hero")
    }
  }

  static func teaser(of achievement: AchievementID) -> String {
    switch achievement {
    case .firstQuestCompleted: String(localized: "Something about beginning", table: "Hero")
    case .firstLevelUp: String(localized: "Something about the first climb", table: "Hero")
    case .firstBronzeStreak: String(localized: "Something about three days", table: "Hero")
    case .firstSilverStreak: String(localized: "Something about a full week", table: "Hero")
    case .firstGoldStreak: String(localized: "Something about winter mornings", table: "Hero")
    case .firstPlatinumStreak: String(localized: "Something about a hundred of anything", table: "Hero")
    case .xp100: String(localized: "Something about the first hundred", table: "Hero")
    case .xp500: String(localized: "Something about five hundred", table: "Hero")
    case .firstSubscriptionConfirmed: String(localized: "Something about money that repeats", table: "Hero")
    case .firstReceiptScanned: String(localized: "Something about a quiet month of spending", table: "Hero")
    case .allStatsTouched: String(localized: "Something about being more than one thing", table: "Hero")
    case .firstFullHPDay: String(localized: "Something about a day with nothing dropped", table: "Hero")
    case .firstCrownBanked: String(localized: "Something about a whole period", table: "Hero")
    case .firstRecoveryCompleted: String(localized: "Something about starting smaller", table: "Hero")
    case .firstLockedDayCleared: String(localized: "Something about deciding in advance", table: "Hero")
    case .firstComebackClaimed: String(localized: "Something you have not attempted yet", table: "Hero")
    case .firstReturnerRitual: String(localized: "Something about coming back twice", table: "Hero")
    }
  }

  /// The reference's words, except Comeback's, which there describes a three-day run the rule (`Rules/Progress.swift`) does not ask for.
  static func description(of achievement: AchievementID) -> String {
    switch achievement {
    case .firstQuestCompleted: String(localized: "The first quest you completed.", table: "Hero")
    case .firstLevelUp: String(localized: "The first level you reached.", table: "Hero")
    case .firstBronzeStreak: String(localized: "A three-day run on any quest.", table: "Hero")
    case .firstSilverStreak: String(localized: "A seven-day run on any quest.", table: "Hero")
    case .firstGoldStreak: String(localized: "A thirty-day run on any quest. It says more about your evenings than your mornings.", table: "Hero")
    case .firstPlatinumStreak: String(localized: "A hundred-day run on one quest.", table: "Hero")
    case .xp100: String(localized: "A hundred experience earned.", table: "Hero")
    case .xp500: String(localized: "Five hundred experience earned.", table: "Hero")
    case .firstSubscriptionConfirmed: String(localized: "The first subscription you confirmed.", table: "Hero")
    case .firstReceiptScanned: String(localized: "The first receipt you scanned into an expense.", table: "Hero")
    case .allStatsTouched: String(localized: "Body, mind, wealth and discipline all moved.", table: "Hero")
    case .firstFullHPDay: String(localized: "A full day with no quest missed.", table: "Hero")
    case .firstCrownBanked: String(localized: "A full crown period with most of its occurrences kept.", table: "Hero")
    case .firstRecoveryCompleted: String(localized: "The first recovery quest you completed.", table: "Hero")
    case .firstLockedDayCleared: String(localized: "A locked day cleared in full.", table: "Hero")
    case .firstComebackClaimed: String(localized: "The first comeback bonus you claimed after recent misses.", table: "Hero")
    case .firstReturnerRitual: String(localized: "The Returner ritual, completed.", table: "Hero")
    }
  }

  static func symbol(of achievement: AchievementID) -> String {
    switch achievement {
    case .firstQuestCompleted: "flag.checkered"
    case .firstLevelUp: "arrow.up.circle"
    case .firstBronzeStreak: "flame"
    case .firstSilverStreak: "flame.fill"
    case .firstGoldStreak: "sun.max.fill"
    case .firstPlatinumStreak: "sparkles"
    case .xp100: "star"
    case .xp500: "star.circle"
    case .firstSubscriptionConfirmed: "arrow.triangle.2.circlepath"
    case .firstReceiptScanned: "doc.text.viewfinder"
    case .allStatsTouched: "square.grid.2x2"
    case .firstFullHPDay: "heart.fill"
    case .firstCrownBanked: "crown"
    case .firstRecoveryCompleted: "leaf"
    case .firstLockedDayCleared: "lock.square"
    case .firstComebackClaimed: "arrow.uturn.backward.circle"
    case .firstReturnerRitual: "arrow.counterclockwise.circle"
    }
  }

  static func name(of title: TitleID) -> String {
    switch title {
    case .steadyBuilder: String(localized: "Steady Builder", table: "Hero")
    case .bodyTempered: String(localized: "Body Tempered", table: "Hero")
    case .wealthDisciplined: String(localized: "Wealth Disciplined", table: "Hero")
    case .mindCultivated: String(localized: "Mind Cultivated", table: "Hero")
    case .anchorHolder: String(localized: "Anchor Holder", table: "Hero")
    case .goalKeeper: String(localized: "Goal Keeper", table: "Hero")
    case .routineForged: String(localized: "Routine Forged", table: "Hero")
    case .quietClimber: String(localized: "Quiet Climber", table: "Hero")
    case .architect: String(localized: "Architect", table: "Hero")
    case .honestPlanner: String(localized: "Honest Planner", table: "Hero")
    case .reflectivePractitioner: String(localized: "Reflective Practitioner", table: "Hero")
    case .restorer: String(localized: "Restorer", table: "Hero")
    case .returner: String(localized: "Returner", table: "Hero")
    case .comebackSteady: String(localized: "Comeback Steady", table: "Hero")
    case .optionalSurplus: String(localized: "Optional Surplus", table: "Hero")
    case .crossStatClimber: String(localized: "Cross-Stat Climber", table: "Hero")
    case .quietYear: String(localized: "Quiet Year", table: "Hero")
    }
  }

  static func earnedFrom(_ title: TitleID) -> String {
    switch title {
    case .steadyBuilder: String(localized: "Discipline at sixty", table: "Hero")
    case .bodyTempered: String(localized: "Body at sixty", table: "Hero")
    case .wealthDisciplined: String(localized: "Wealth at sixty", table: "Hero")
    case .mindCultivated: String(localized: "Mind at sixty", table: "Hero")
    case .anchorHolder: String(localized: "Thirty days on an anchor", table: "Hero")
    case .goalKeeper: String(localized: "Thirty goal quests kept", table: "Hero")
    case .routineForged: String(localized: "A hundred routine quests kept", table: "Hero")
    case .quietClimber: String(localized: "A week-long run on three quests", table: "Hero")
    case .architect: String(localized: "Ten locked days cleared", table: "Hero")
    case .honestPlanner: String(localized: "Ten moves logged with a reason", table: "Hero")
    case .reflectivePractitioner: String(localized: "Twenty reasons across twenty days", table: "Hero")
    case .restorer: String(localized: "Five recovery quests kept", table: "Hero")
    case .returner: String(localized: "The first quest after a return", table: "Hero")
    case .comebackSteady: String(localized: "Ten comebacks", table: "Hero")
    case .optionalSurplus: String(localized: "Thirty optional quests kept", table: "Hero")
    case .crossStatClimber: String(localized: "All four stats at thirty", table: "Hero")
    case .quietYear: String(localized: "A year of days with something kept", table: "Hero")
    }
  }

  static func name(of cosmetic: CosmeticID) -> String {
    switch cosmetic {
    case .badgeBronze: String(localized: "Bronze badge", table: "Hero")
    case .badgeSilver: String(localized: "Silver badge", table: "Hero")
    case .badgeGoldStreak: String(localized: "Gold streak badge", table: "Hero")
    case .accentEmber: String(localized: "Ember accent", table: "Hero")
    case .accentFrost: String(localized: "Frost accent", table: "Hero")
    case .accentAuroraPlatinum: String(localized: "Aurora accent", table: "Hero")
    case .themeSunrise: String(localized: "Sunrise theme", table: "Hero")
    case .themeMidnight: String(localized: "Midnight theme", table: "Hero")
    case .themeReturner: String(localized: "Returner theme", table: "Hero")
    }
  }

  static func note(of cosmetic: CosmeticID) -> String {
    switch cosmetic {
    case .badgeBronze: String(localized: "The crest you started with.", table: "Hero")
    case .badgeSilver: String(localized: "Plain, heavy and slow to earn.", table: "Hero")
    case .badgeGoldStreak: String(localized: "Comes with an achievement, never with coins.", table: "Hero")
    case .accentEmber: String(localized: "A warm edge on the hero card.", table: "Hero")
    case .accentFrost: String(localized: "A cold steel edge on the hero card.", table: "Hero")
    case .accentAuroraPlatinum: String(localized: "A radiant edge on the hero card. Comes with a hundred-day run.", table: "Hero")
    case .themeSunrise: String(localized: "A lighter accent across every surface.", table: "Hero")
    case .themeMidnight: String(localized: "Deep indigo in light mode and moonlit indigo in dark, across every surface.", table: "Hero")
    case .themeReturner: String(localized: "A warm accent across every surface. Comes with the Returner ritual.", table: "Hero")
    }
  }

  static func symbol(of cosmetic: CosmeticID) -> String {
    switch cosmetic {
    case .badgeBronze: "seal"
    case .badgeSilver: "shield"
    case .badgeGoldStreak: "rosette"
    case .accentEmber: "flame"
    case .accentFrost: "snowflake"
    case .accentAuroraPlatinum: "sparkles"
    case .themeSunrise: "sunrise"
    case .themeMidnight: "moon.stars"
    case .themeReturner: "arrow.counterclockwise.circle"
    }
  }
}

import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir hero deck and coming back", TestTimeLimit.quick)
struct HeroReadTests {
  private typealias Device = ReadsDevice

  @Test func shouldShowTheLevelCoinsStatsProgressionAndCrownHistory() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.questComplete(Occurrence(quest: Device.anchor, date: Device.day(0))), on: Device.day(0), minute: 425)
    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 490)
    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(1))), on: Device.day(1), minute: 490)
    try await device.walk(to: Device.day(2))
    let deck = try await device.load(HeroDeck.self, HeroDeckQuery())
    let state = Replay.run(try await device.store.read { transaction in try Replay.commands(in: transaction) }, through: device.horizon.function())

    #expect(deck.level.totalXP == state.hero.totalXP && deck.coins == state.hero.coins && deck.level.level == 1)
    #expect(deck.level.xpIntoLevel == state.hero.totalXP && deck.level.xpForNextLevel == Ruleset.v1.level.xpToAdvance(fromLevel: 1) && !deck.level.isHighestLevel)
    #expect(deck.stats.map(\.stat) == [.body, .mind, .wealth, .discipline], "synced-hero-provider.ts:52")
    #expect(deck.stats.map(\.value) == [2, 1, 0, 0] && deck.stats.map(\.percentOfBest) == [100, 50, 0, 0], "synced-hero-provider.ts:170-180")
    #expect(deck.progression.count <= HeroDeckQuery.defaultEventLimit && !deck.progression.isEmpty)
    #expect(deck.progression.allSatisfy { $0.event.type != .crownInit }, "synced-hero-provider.ts:61")
    #expect(zip(deck.progression, deck.progression.dropFirst()).allSatisfy { $0.ordinal > $1.ordinal }, "latest first")
    let kept = try #require(deck.progression.first { $0.event.type == .questComplete && $0.event.quest == Device.routine })
    #expect(kept.questName == "Run" && kept.isRewarded)
    #expect(deck.crownHistory.map(\.closedOn) == [Device.day(0), Device.day(1)] && deck.crownHistory.allSatisfy { $0.periodStart == $0.closedOn })
    #expect(deck.crownHistory.map(\.banked) == [Device.day(0), Device.day(1)].map { state.days[$0]?.crown?.banked })
    #expect(deck.achievements.map(\.id) == AchievementID.allCases && deck.achievements.first { $0.id == .firstQuestCompleted }?.earnedOn == Device.day(0))
    #expect(deck.achievements.first { $0.id == .firstGoldStreak }?.unlocks == .badgeGoldStreak && deck.achievementsEarned == state.progression.achievements.count)
    #expect(deck.name == .untitled && deck.titles.allSatisfy { $0.earnedOn == nil && !$0.isDisplayed })
    #expect(deck.shields == ShieldStanding(available: 0, cap: 3 * Ruleset.v1.shields.capPerQuest), "hero-standing.service.ts:55-59: Optional keeps no streak")
    #expect(deck.momentum == .measured(try #require(state.days[Device.day(2)]?.momentum)) && deck.activeDays == 2 && deck.questsCompleted == 3)
    #expect(deck.crown?.periodStart == Device.day(2) && deck.hp == state.days[Device.day(2)]?.hp)
  }

  /// `synced-hero-provider.ts:141-153`.
  @Test func shouldSayWhichCosmeticsAreEquippedOwnedAffordableShortOrAnAchievementsOnly() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.questComplete(Occurrence(quest: Device.anchor, date: Device.day(0))), on: Device.day(0), minute: 425)
    try await device.walk(to: Device.day(0))
    let deck = try await device.load(HeroDeck.self, HeroDeckQuery())
    let states = Dictionary(uniqueKeysWithValues: deck.cosmetics.map { ($0.id, $0.state) })
    #expect(deck.coins == 2 && states[.badgeBronze] == .short(by: 48) && states[.themeSunrise] == .short(by: 73))
    #expect(states[.badgeGoldStreak] == .achievementOnly(.firstGoldStreak) && states[.themeReturner] == .achievementOnly(.firstReturnerRitual))
    #expect(deck.cosmetics.first { $0.id == .accentEmber }?.kind == .heroAccent && deck.cosmetics.first { $0.id == .accentEmber }?.priceCoins == 100)

    let equipped = UnlockRow(kind: .cosmetic, id: CosmeticID.themeReturner.rawValue, unlockedOn: nil, source: .achievement, equipped: true)
    let owned = UnlockRow(kind: .cosmetic, id: CosmeticID.badgeBronze.rawValue, unlockedOn: nil, source: .coin, equipped: false)
    #expect(HeroDeck.state(of: .themeReturner, owned: equipped, coins: 0) == .equipped(.achievement))
    #expect(HeroDeck.state(of: .badgeBronze, owned: owned, coins: 0) == .owned(.coin))
    #expect(HeroDeck.state(of: .badgeBronze, owned: nil, coins: 50) == .affordable)
  }

  @Test func shouldNameTheHeroByTheDisplayedTitleOrAskForOneOnceEarned() {
    #expect(HeroDeck.name(displayed: .architect, anyEarned: true) == .title(.architect))
    #expect(HeroDeck.name(displayed: nil, anyEarned: true) == .chooseTitle)
    #expect(HeroDeck.name(displayed: nil, anyEarned: false) == .untitled)
  }

  @Test func shouldExplainARecoveryReturnWithTheWeeksMissesAndItsChoices() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    for quest in [Device.goal, Device.optional] { try await device.issue(.questComplete(Occurrence(quest: quest, date: Device.day(0))), on: Device.day(0)) }
    try await device.issue(.accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)), on: Device.day(1))
    try await device.walk(to: Device.day(1))
    let back = try await device.load(ComingBack.self, ComingBackQuery())

    #expect(back.reason == .recovery && back.choices == [.keepRecoveryQuest, .reviewWeek] && !back.comebackClaimed)
    #expect(back.recovery?.sourceQuest == Device.anchor && back.recovery?.complete == .available)
    #expect(Set(back.recentlyMissed.map(\.quest)) == [Device.anchor, Device.routine] && back.recentlyMissed.allSatisfy { $0.misses.map(\.date) == [Device.day(0)] })
    #expect(back.recentlyMissed.map(\.name).sorted { ($0 ?? "") < ($1 ?? "") } == ["Morning pages", "Run"])
    #expect(back.comeback?.armed == true && back.comeback?.allowance == Ruleset.v1.comeback.maxFiresPerDay)
    #expect(back.intensityMode == .standard && back.pendingIntensityMode == .lowIntensity, "staged, so never shown as in force")
    #expect(back.returnerThresholdDays == Ruleset.v1.returner.defaultThresholdDays && back.lastActiveDate == Device.day(0))

    try await device.walk(to: Device.day(2))
    let later = try await device.load(ComingBack.self, ComingBackQuery())
    #expect(later.intensityMode == .lowIntensity && later.pendingIntensityMode == nil)
  }

  @Test func shouldExplainAReturnerReturnAndWhereItsShieldWent() async throws {
    let device = try Device()
    try await device.create(Device.routine, "Run", schedule: try Device.schedule(.routine, start: 480))
    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 490)
    try await device.walk(to: Device.day(8))
    let back = try await device.load(ComingBack.self, ComingBackQuery())
    #expect(back.reason == .returner && back.choices == [.keepOneQuestToday, .reviewWeek])
    #expect(back.returner == ReturnerStanding(lastActiveDate: Device.day(0), daysAbsent: 8, shieldTarget: Device.routine, shieldTargetName: "Run", shieldPending: false))
    #expect(back.shields.available == 1 && back.recentlyMissed.first?.misses.count == RecentMisses.windowDays, "lib/sync/projection.ts:983-1001")
    #expect(try await device.load(HeroDeck.self, HeroDeckQuery()).comingBack == .returner)
  }

  /// `synced-hero-provider.ts:110-138,161-165`.
  @Test func shouldOfferTheChoicesForEachReason() {
    #expect(ComingBack.choices(for: nil, claimed: false) == [])
    #expect(ComingBack.choices(for: .comeback, claimed: false) == [.keepComebackQuest, .reviewWeek])
    #expect(ComingBack.choices(for: .comeback, claimed: true) == [.reviewWeek])
  }

  @Test func shouldReadAnEmptyDeckBeforeAnyCommand() async throws {
    let device = try Device()
    let deck = try await device.load(HeroDeck.self, HeroDeckQuery())
    #expect(deck.level.level == 1 && deck.coins == 0 && deck.crown == nil && deck.progression.isEmpty && deck.cosmetics.count == CosmeticID.allCases.count)
    let back = try await device.load(ComingBack.self, ComingBackQuery())
    #expect(back.openDay == nil && back.reason == nil && back.choices.isEmpty)
  }
}

import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("HeroModel", TestTimeLimit.standard)
struct HeroModelTests {
  private let scratch = ScratchDefaults()

  private func model(_ world: HeroWorld) -> HeroModel {
    HeroModel(context: world.context, acknowledgements: WithdrawalAcknowledgements(defaults: scratch.defaults))
  }

  private func running(_ world: HeroWorld) async throws -> (HeroModel, Task<Void, Never>) {
    let model = self.model(world)
    let task = Task { await model.run() }
    try await until("the deck") { model.deck.state.value != nil }
    return (model, task)
  }

  @Test("should load the deck, then emit it again when a command lands")
  func loadsAndReEmits() async throws {
    let world = try await HeroWorld()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let first = try #require(model.deck.state.value)
    #expect(first.level.level == 1 && first.coins == 0 && first.progression.isEmpty && first.name == .untitled)
    try await until("today") { model.today == TestClock.day(0) }

    let quests = try await world.createQuests(["Morning pages"], strictness: .anchor)
    try await world.complete(quests, on: 0)

    try await until("the kept quest") { model.deck.state.value?.progression.isEmpty == false }
    let deck = try #require(model.deck.state.value)
    #expect(deck.coins == 2, "an anchor kept on time pays two coins (Ruleset+V1)")
    #expect(deck.progression.contains { $0.questName == "Morning pages" && $0.isRewarded })
    #expect(deck.achievements.first { $0.id == .firstQuestCompleted }?.earnedOn == TestClock.day(0))
  }

  @Test("should display an earned title through title.display, then clear it")
  func displaysAndClearsATitle() async throws {
    let world = try await HeroWorld()
    try await world.returnAfterABreak()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    try await until("the Returner title") { model.deck.state.value?.titles.first { $0.id == .returner }?.earnedOn != nil }
    #expect(model.deck.state.value?.name == .chooseTitle)

    await model.display(.returner)

    #expect(try await world.commands().last == .titleDisplay(TitleDisplay(title: .returner)))
    try await until("the displayed title") { model.deck.state.value?.name == .title(.returner) }
    #expect(model.failure == nil && model.pending == nil)

    await model.clearTitle()

    #expect(try await world.commands().last == .titleDisplay(TitleDisplay(title: nil)))
    try await until("no displayed title") { model.deck.state.value?.name == .chooseTitle }
  }

  @Test("should refuse a title not earned in the reference's words and write nothing")
  func refusesAnUnearnedTitle() async throws {
    let world = try await HeroWorld()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let before = try await world.commands()

    await model.display(.architect)

    #expect(model.failure == HeroFailure(action: .display(.architect), error: PresentedError(headline: "That title hasn’t been earned yet.", detail: "memoir_replay.ttl_001")))
    #expect(try await world.commands() == before)
  }

  @Test("should buy an affordable cosmetic through cosmetic.purchase, then equip it through cosmetic.equip")
  func buysAndEquips() async throws {
    let world = try await HeroWorld()
    try await world.earnCoins()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    try await until("enough coins") { (model.deck.state.value?.coins ?? 0) >= 75 }
    let coins = try #require(model.deck.state.value?.coins)

    await model.unlock(.themeSunrise)

    #expect(try await world.commands().last == .cosmeticPurchase(.themeSunrise))
    try await until("the theme owned") { Self.state(of: .themeSunrise, in: model) == .owned(.coin) }
    #expect(model.deck.state.value?.coins == coins - 75)

    await model.equip(.themeSunrise)

    #expect(try await world.commands().last == .cosmeticEquip(.themeSunrise))
    try await until("the theme equipped") { Self.state(of: .themeSunrise, in: model) == .equipped(.coin) }
    #expect(model.failure == nil)
  }

  @Test("should refuse an overspend, an equip of something not owned and a purchase of an achievement's item in the reference's words, writing nothing")
  func refusesWhatTheDeckRulesOut() async throws {
    let world = try await HeroWorld()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let before = try await world.commands()

    await model.unlock(.accentEmber)
    let overspend = PresentedError(headline: "You don’t have enough coins for that.", detail: "memoir_replay.hro_001")
    #expect(model.failure == HeroFailure(action: .unlock(.accentEmber), error: overspend))

    await model.equip(.accentEmber)
    #expect(model.failure == HeroFailure(action: .equip(.accentEmber), error: PresentedError(headline: "Unlock it before equipping it.", detail: "memoir_replay.csm_003")))

    await model.unlock(.badgeGoldStreak)
    #expect(
      model.failure
        == HeroFailure(
          action: .unlock(.badgeGoldStreak),
          error: PresentedError(headline: "That item comes with an achievement, not with coins.", detail: "memoir_command.cosmetic_not_for_sale")))

    #expect(try await world.commands() == before)
  }

  @Test("should show a purchase replay withdrew for want of coins once, in the reference's words, until the owner dismisses it")
  func showsAndDismissesAWithdrawnPurchase() async throws {
    let world = try await HeroWorld()
    let (model, task) = try await running(world)
    defer { task.cancel() }

    let first = try await world.context.writer.issue(.cosmeticPurchase(.accentEmber))
    let second = try await world.context.writer.issue(.cosmeticPurchase(.accentEmber))

    try await until("both withdrawals") { model.deck.state.value?.notices.count == 2 }
    let withdrawn = WithdrawnPurchase(cosmetic: .accentEmber, refusal: .notEnoughCoins(balance: 0, required: 100), commands: [second.id, first.id])
    #expect(model.withdrawnPurchases == [withdrawn])
    #expect(WritingErrors.headline(for: withdrawn.refusal) == "You don’t have enough coins for that.")
    #expect(Self.state(of: .accentEmber, in: model) == .short(by: 100))

    model.acknowledge(withdrawn)
    #expect(model.withdrawnPurchases.isEmpty)

    let frost = try await world.context.writer.issue(.cosmeticPurchase(.accentFrost))
    try await until("the deck to emit again") { model.deck.state.value?.notices.count == 3 }
    #expect(model.withdrawnPurchases.map(\.commands) == [[frost.id]], "the dismissed one stays hidden")

    let later = self.model(world)
    let laterTask = Task { await later.run() }
    defer { laterTask.cancel() }
    try await until("a later screen's deck") { later.deck.state.value?.notices.count == 3 }
    #expect(later.withdrawnPurchases.map(\.cosmetic) == [.accentFrost], "dismissed on this device, so hidden on the next visit too")
  }

  @Test("should show a write that fails past the checks, clear the pending action and write nothing")
  func showsAFailedWrite() async throws {
    let world = try await HeroWorld()
    try await world.returnAfterABreak()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    try await until("the Returner title") { model.deck.state.value?.titles.first { $0.id == .returner }?.earnedOn != nil }
    let before = try await world.commands()
    world.breakTheClock()

    await model.display(.returner)

    #expect(model.failure?.action == .display(.returner))
    #expect(model.failure?.error.headline == "The date on this device is outside the years Memoir can record. Check the device’s date and time.")
    #expect(model.pending == nil)
    #expect(try await world.commands() == before)
  }

  @Test("should show nothing for a write cancelled with its task, and clear the pending action")
  func showsNothingForACancelledWrite() async throws {
    let world = try await HeroWorld()
    try await world.returnAfterABreak()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    try await until("the Returner title") { model.deck.state.value?.titles.first { $0.id == .returner }?.earnedOn != nil }
    let before = try await world.commands()

    let displaying = Task { await model.display(.returner) }
    displaying.cancel()
    await displaying.value

    #expect(model.failure == nil && model.pending == nil)
    #expect(try await world.commands() == before)
  }

  @Test("should offer the Bronze badge as the starter crest, equipped while no badge is, and never for coins")
  func offersTheStarterCrest() async throws {
    let world = try await HeroWorld()
    try await world.returnAfterABreak()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    try await until("the Returner theme") { Self.state(of: .themeReturner, in: model) == .owned(.achievement) }
    let deck = try #require(model.deck.state.value)
    let offers = Dictionary(uniqueKeysWithValues: deck.cosmetics.map { ($0.id, CosmeticOffer($0, in: deck)) })

    #expect(offers[.badgeBronze] == .starter(equipped: true))
    #expect(offers[.badgeSilver] == .short(by: 150 - deck.coins))
    #expect(offers[.badgeGoldStreak] == .achievementOnly)
    #expect(offers[.themeReturner] == .owned)
  }

  private static func state(of cosmetic: CosmeticID, in model: HeroModel) -> CosmeticState? {
    model.deck.state.value?.cosmetics.first { $0.id == cosmetic }?.state
  }
}

@MainActor
@Suite("Hero copy", TestTimeLimit.quick)
struct HeroCopyTests {
  private let bundle = Bundle(for: HeroModel.self)

  private func hasCopy(_ text: String) -> Bool {
    !text.isEmpty && bundle.localizedString(forKey: text, value: "missing", table: "Hero") != "missing"
  }

  @Test("should have a name and words in Hero.xcstrings for every achievement, title and cosmetic the core defines")
  func coversEveryCatalogueID() {
    for id in AchievementID.allCases {
      #expect(hasCopy(HeroCatalogue.name(of: id)) && hasCopy(HeroCatalogue.teaser(of: id)) && hasCopy(HeroCatalogue.description(of: id)), "\(id)")
    }
    for id in TitleID.allCases { #expect(hasCopy(HeroCatalogue.name(of: id)) && hasCopy(HeroCatalogue.earnedFrom(id)), "\(id)") }
    for id in CosmeticID.allCases { #expect(hasCopy(HeroCatalogue.name(of: id)) && hasCopy(HeroCatalogue.note(of: id)), "\(id)") }
    for mode in IntensityMode.allCases { #expect(hasCopy(HeroCopy.intensity(mode)) && hasCopy(HeroCopy.intensityDescription(mode)), "\(mode)") }
    for stat in StatAffinity.allCases { #expect(hasCopy(HeroCopy.stat(stat)) && hasCopy(HeroCopy.statNote(stat)), "\(stat)") }

    #expect(Set(AchievementID.allCases.map(HeroCatalogue.name(of:))).count == AchievementID.allCases.count)
    #expect(Set(TitleID.allCases.map(HeroCatalogue.name(of:))).count == TitleID.allCases.count)
    #expect(Set(CosmeticID.allCases.map(HeroCatalogue.name(of:))).count == CosmeticID.allCases.count)
  }

  @Test("should read a missing key as missing, so the completeness check can fail")
  func detectsAMissingKey() {
    #expect(!hasCopy("A cosmetic the catalogue never had"))
  }

  @Test("should name today and yesterday, and date other days")
  func namesRelativeDays() {
    let today = TestClock.day(10)
    #expect(HeroDates.relative(TestClock.day(10), today: today) == "Today")
    #expect(HeroDates.relative(TestClock.day(9), today: today) == "Yesterday")
    #expect(HeroDates.relative(TestClock.day(3), today: today) == HeroDates.text(TestClock.day(3), year: false))
    #expect(HeroDates.text(LocalDate(isoString: "2026-03-05")!, year: false).contains("5"))
  }

  @Test("should use the reference's words for the replay refusals the Hero screen shows")
  func usesReferenceWordsForReplayRefusals() {
    #expect(WritingErrors.presented(ReplayRefusal.notEnoughCoins(balance: 3, required: 75))?.headline == "You don’t have enough coins for that.")
    #expect(WritingErrors.presented(ReplayRefusal.cosmeticNotOwned(.accentFrost))?.headline == "Unlock it before equipping it.")
    #expect(WritingErrors.presented(ReplayRefusal.titleNotEarned(.architect))?.headline == "That title hasn’t been earned yet.")
  }
}

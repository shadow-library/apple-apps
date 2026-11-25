import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import MemoirCore

@Suite("Memoir module changes", TestTimeLimit.standard)
struct ModuleChangesTests {
  private typealias Device = ReadsDevice

  private final class Now: Sendable {
    private let value: Mutex<Date>

    init(_ day: LocalDate, minute: Int = 600) {
      value = Mutex(Now.date(day, minute: minute))
    }

    static func date(_ day: LocalDate, minute: Int) -> Date {
      Date(timeIntervalSince1970: Double(Device.stamp(day, minute: minute).instantMillis) / 1000)
    }

    var date: Date { value.withLock { $0 } }

    func set(_ day: LocalDate, minute: Int = 600) {
      value.withLock { $0 = Now.date(day, minute: minute) }
    }
  }

  private struct World {
    let device: Device
    let stores: MemoirStores
    let now: Now

    var changes: ModuleChanges {
      let now = now
      let source = CommandIssuerSource { _ in CommandIssuer(clock: IssueClock(timeZone: .gmt), wallClock: { now.date }) }
      return ModuleChanges(stores: stores, issuer: source, now: { now.date })
    }

    func settings() async throws -> AccountSettingsRecord? {
      try await stores.main.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record }
    }

    func activeQuests() async throws -> Set<UUID> {
      Set(try await stores.main.read { transaction in try MemoirDerived.quests(in: transaction) }.filter(\.schedule.active).map(\.id))
    }

    func missed(from start: LocalDate) async throws -> [Occurrence] {
      try await stores.main.read { transaction in
        try MemoirDerived.questLogs(from: start, through: .latest, in: transaction).filter { $0.entry.state == .missed }.map(\.occurrence)
      }
    }

    func commandCount() async throws -> Int {
      try await stores.main.read { transaction in try transaction.states(ofKind: MemoirKind.command.entityKind, scope: .vault).count }
    }
  }

  private static func open(settings: AccountSettingsRecord? = nil, quests: Bool = false) async throws -> World {
    nonisolated(unsafe) var opened: MemoirStores?
    let device = try Device { reconciler in
      let stores = try MemoirStores.openInMemory(projection: reconciler)
      opened = stores
      return stores.main
    }
    let stores = try #require(opened)
    if let settings { try await MoneyReadsFixture.seed(stores.main, [settings]) }
    if quests { try await device.createStandardQuests() }
    return World(device: device, stores: stores, now: Now(Device.day(0)))
  }

  private static func settings(_ change: (inout AccountSettingsRecord) -> Void = { _ in }) throws -> AccountSettingsRecord {
    let euro = try MemoirStoreFixture.currency("EUR")
    var settings = AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro])
    change(&settings)
    return settings
  }

  private static func edit(_ world: World, _ change: @escaping @Sendable (inout AccountSettingsRecord) -> Void) async throws {
    _ = try await world.stores.main.write { transaction in try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { change(&$0) } }
  }

  private static func claimReader(in world: World) async throws -> HealthReaderDesignation {
    try await world.stores.main.write { transaction in
      _ = try HealthSettings.claim(HealthFixture.tablet, takingOver: true, atMillis: 1, in: &transaction)
      try HealthSettings.setActivityOnICloud(true, in: &transaction)
    }
    return try #require(try await world.stores.main.read { transaction in try HealthSettings.designation(in: transaction) })
  }

  private static func health(in world: World) async throws -> (reader: HealthReaderDesignation?, activity: Bool) {
    try await world.stores.main.read { transaction in
      (reader: try HealthSettings.designation(in: transaction), activity: try HealthSettings.isActivityOnICloud(in: transaction))
    }
  }

  @Test func shouldPauseEveryActiveQuestInTheSameWriteSoReplayMissesNothingAfterTheChangeDay() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    try await world.device.walk(to: Device.day(2))
    #expect(try await world.missed(from: Device.day(0)).contains(Occurrence(quest: Device.routine, date: Device.day(1))), "the quests miss while active")
    let before = try await world.commandCount()

    world.now.set(Device.day(2))
    #expect(try await world.changes.preview(.quests, enabled: false).pausedQuests == [Device.anchor, Device.routine, Device.goal, Device.optional])
    #expect(try await world.commandCount() == before, "a preview writes nothing")
    let change = try await world.changes.apply(.quests, enabled: false)

    #expect(change.pausedQuests == [Device.anchor, Device.routine, Device.goal, Device.optional])
    #expect(change.turnedOff == [.quests] && change.turnedOn.isEmpty)
    #expect(try await world.commandCount() == before + 4)
    #expect(try await world.settings()?.moduleQuests == false)
    #expect(try await world.activeQuests().isEmpty, "the projection settled the pause with the write")
    #expect(try await world.device.outcomes().values.allSatisfy { $0 == .applied })

    try await world.device.walk(to: Device.day(9))
    #expect(try await world.missed(from: Device.day(3)).isEmpty)
    #expect(try await world.missed(from: Device.day(2)).isEmpty, "paused before the change day closed")
  }

  @Test func shouldReactivateNothingWhenQuestsTurnBackOn() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    try await world.device.walk(to: Device.day(1))
    world.now.set(Device.day(1))
    try await world.changes.apply(.quests, enabled: false)
    let paused = try await world.commandCount()

    let change = try await world.changes.apply(.quests, enabled: true)
    #expect(change.turnedOn == [.quests] && change.pausedQuests.isEmpty)
    #expect(try await world.commandCount() == paused, "turning quests on issues nothing")
    #expect(try await world.activeQuests().isEmpty)
    #expect(try await world.settings()?.moduleQuests == true)
  }

  @Test func shouldApplyTheChangeToTheRecordAsTheWriteReadsItSoAnotherDevicesChangeSurvives() async throws {
    let world = try await Self.open(settings: try Self.settings())
    let preview = try await world.changes.preview(.journal, enabled: false)
    #expect(preview.after.modules == Set(MemoirModule.allCases).subtracting([.journal]))
    try await Self.edit(world) { $0.setModule(.meals, enabled: false) }

    let change = try await world.changes.apply(.journal, enabled: false)
    #expect(change.before.modules == Set(MemoirModule.allCases).subtracting([.meals]) && change.turnedOff == [.journal])
    let settings = try #require(try await world.settings())
    #expect(settings.modules == [.hero, .quests, .money, .body])
    #expect([settings.moduleHero, settings.moduleQuests, settings.moduleMoney, settings.moduleBody].allSatisfy { $0 == nil }, "only the fields that moved")
  }

  @Test func shouldTakeSeveralModulesAtOnceForAStepNoSingleModuleMakesValid() async throws {
    let world = try await Self.open(
      settings: try Self.settings { settings in
        for module in MemoirModule.allCases where module != .journal { settings.setModule(module, enabled: false) }
      })
    for module in [MemoirModule.hero, .quests] {
      await #expect(throws: ModuleChangeError.self) { try await world.changes.apply(module, enabled: true) }
    }
    let change = try await world.changes.apply([.hero: true, .quests: true])
    #expect(change.turnedOn == [.hero, .quests])
    #expect(try await world.settings()?.modules == [.hero, .quests, .journal])
  }

  @Test func shouldRefuseAChangeThatBreaksTheLawsAndWriteNothing() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    let before = try await world.commandCount()
    for (module, refusal) in [(MemoirModule.hero, ModuleSelectionError.questsNeedHero)] {
      do {
        try await world.changes.apply(module, enabled: false)
        Issue.record("turning \(module) off was accepted")
      } catch {
        guard case .refused(let reason) = error else { throw error }
        #expect(reason == refusal && error.code == refusal.code)
      }
    }
    let moneyOnly = try await Self.open(
      settings: try Self.settings { settings in
        for module in MemoirModule.allCases where module != .money { settings.setModule(module, enabled: false) }
      })
    await #expect(throws: ModuleChangeError.self) { try await moneyOnly.changes.apply(.money, enabled: false) }
    #expect(try await world.commandCount() == before)
    #expect(try await world.settings()?.moduleHero == nil)
  }

  @Test func shouldSetMoneyScoredFromOnceWhenHeroAndMoneyFirstMeet() async throws {
    let world = try await Self.open(
      settings: try Self.settings { settings in
        settings.setModule(.hero, enabled: false)
        settings.setModule(.quests, enabled: false)
      })

    world.now.set(Device.day(3))
    #expect(try await world.changes.apply(.journal, enabled: false).moneyScoredFrom == nil, "hero stays off")
    #expect(try await world.settings()?.moneyScoredFrom == nil)
    #expect(try await world.changes.preview(.hero, enabled: true).moneyScoredFrom == Device.day(3))
    #expect(try await world.settings()?.moneyScoredFrom == nil, "a preview writes nothing")
    let first = try await world.changes.apply(.hero, enabled: true)
    #expect(first.moneyScoredFrom == Device.day(3) && first.turnedOn == [.hero])
    #expect(try await world.settings()?.moneyScoredFrom == Device.day(3))

    world.now.set(Device.day(8))
    try await world.changes.apply(.hero, enabled: false)
    let again = try await world.changes.apply(.hero, enabled: true)
    #expect(again.moneyScoredFrom == nil)
    #expect(try await world.settings()?.moneyScoredFrom == Device.day(3), "set once")
  }

  @Test func shouldScoreMoneyFromTheOpenDayWhenItRunsAheadOfTheZoneDate() async throws {
    let world = try await Self.open(
      settings: try Self.settings { settings in
        settings.setModule(.hero, enabled: false)
        settings.setModule(.quests, enabled: false)
      })
    try await world.device.create(Device.routine, nil, schedule: try Device.schedule(.routine, start: 480))
    try await world.device.walk(to: Device.day(4))
    world.now.set(Device.day(3))
    #expect(try await world.changes.apply(.hero, enabled: true).moneyScoredFrom == Device.day(4))
  }

  @Test func shouldLeaveMoneyScoredFromUnsetWhenHeroAndMoneyWereAlreadyOn() async throws {
    let world = try await Self.open(settings: try Self.settings())
    let change = try await world.changes.apply(.journal, enabled: false)
    #expect(change.moneyScoredFrom == nil && change.turnedOff == [.journal])
    let settings = try #require(try await world.settings())
    #expect(settings.moneyScoredFrom == nil)
    #expect(settings.moduleJournal == false)
    #expect([settings.moduleHero, settings.moduleQuests, settings.moduleMoney, settings.moduleMeals, settings.moduleBody].allSatisfy { $0 == nil }, "only the field that moved")
  }

  @Test func shouldClearAnotherDevicesHealthReaderAndKeepActivityOffICloudWhenBodyTurnsOff() async throws {
    let world = try await Self.open(settings: try Self.settings())
    let reader = try await Self.claimReader(in: world)

    let change = try await world.changes.apply(.body, enabled: false)
    #expect(change.clearedReader == reader && change.activityLeavesICloud && change.turnedOff == [.body])
    let health = try await Self.health(in: world)
    #expect(health.reader == nil && !health.activity)

    let on = try await world.changes.apply(.body, enabled: true)
    #expect(on.clearedReader == nil && !on.activityLeavesICloud)
    #expect(try await Self.health(in: world).reader == nil, "turning body on claims nothing")
  }

  @Test func shouldWriteNoHealthSettingsWhenBodyTurnsOffWithNothingToClear() async throws {
    let world = try await Self.open(settings: try Self.settings())
    let change = try await world.changes.apply(.body, enabled: false)
    #expect(change.clearedReader == nil && !change.activityLeavesICloud)
    #expect(try await world.stores.main.read { transaction in try HealthSettingsRecord.read(key: .healthSettings, in: transaction) } == .absent)
  }

  @Test func shouldTurnBodyOffAndPauseQuestsBesideAHealthSettingsRecordThisBuildCannotRead() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    let ref = MemoirKey.healthSettings.ref
    _ = try await world.stores.main.write { transaction in try transaction.set(ref, ["natural_key": MemoirKey.healthSettings.stored, "activity_on_icloud": "yes"]) }

    let change = try await world.changes.apply([.body: false, .quests: false])
    #expect(change.clearedReader == nil && !change.activityLeavesICloud && change.turnedOff == [.body, .quests])
    #expect(try await world.activeQuests().isEmpty)
    #expect(try await world.changes.enforce() == nil)
    let health = try await world.stores.main.read { transaction in try HealthSettingsRecord.read(key: .healthSettings, in: transaction) }
    guard case .unreadable = health else { throw MemoirFixtureError(description: "the record was rewritten: \(health)") }
  }

  @Test func shouldWriteBackAMergedSelectionAsItReadsBesideTheChange() async throws {
    let world = try await Self.open(
      settings: try Self.settings { settings in
        for module in MemoirModule.allCases where module != .hero { settings.setModule(module, enabled: false) }
      })
    let change = try await world.changes.apply(.journal, enabled: true)
    #expect(change.before.modules == [.hero, .money] && change.turnedOn == [.journal])
    #expect(try await world.settings()?.modules == [.hero, .money, .journal])
  }

  @Test func shouldEnforceTheOffModulesOnWhatALaggingDeviceWrote() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    try await world.device.walk(to: Device.day(0), minute: 600)
    try await world.changes.apply(.quests, enabled: false)
    try await world.changes.apply(.body, enabled: false)
    #expect(try await world.changes.enforce() == nil, "nothing to enforce right after the change")

    try await world.device.create(Self.straggler, "Swim", schedule: try Device.schedule(.routine, start: 540))
    let reader = try await Self.claimReader(in: world)
    let before = try await world.commandCount()
    let enforced = try #require(try await world.changes.enforce())
    #expect(enforced.pausedQuests == [Self.straggler] && enforced.clearedReader == reader && enforced.activityLeavesICloud)
    #expect(enforced.turnedOn.isEmpty && enforced.turnedOff.isEmpty)
    #expect(try await world.commandCount() == before + 1)
    #expect(try await world.activeQuests().isEmpty)
    let health = try await Self.health(in: world)
    #expect(health.reader == nil && !health.activity)
    #expect(try await world.changes.enforce() == nil)
    #expect(try await world.commandCount() == before + 1)
  }

  @Test func shouldEnforceNothingWhileTheModulesAreOnOrTheVaultHasNoSettings() async throws {
    let world = try await Self.open(settings: try Self.settings(), quests: true)
    _ = try await Self.claimReader(in: world)
    let settings = try await world.settings()
    let before = try await world.commandCount()
    #expect(try await world.changes.enforce() == nil)
    #expect(try await world.commandCount() == before)
    #expect(try await world.activeQuests().count == 4)
    #expect(try await Self.health(in: world).reader != nil)
    #expect(try await world.settings() == settings)

    let bare = try await Self.open(quests: true)
    #expect(try await bare.changes.enforce() == nil)
    #expect(try await bare.settings() == nil)
  }

  @Test func shouldRefuseAVaultWithoutSettingsAndWriteNothing() async throws {
    let world = try await Self.open(quests: true)
    let before = try await world.commandCount()
    let attempts: [@Sendable () async throws -> ModuleChange] = [
      { try await world.changes.apply(.quests, enabled: false) }, { try await world.changes.preview(.quests, enabled: false) },
    ]
    for attempt in attempts {
      do {
        _ = try await attempt()
        Issue.record("a change without a settings record was accepted")
      } catch let error as ModuleChangeError {
        guard case .settingsAbsent = error else { throw error }
        #expect(error.code == "memoir_modules.settings_absent")
      }
    }
    #expect(try await world.commandCount() == before)
    #expect(try await world.settings() == nil)
  }

  private static let straggler = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f0a1")
}

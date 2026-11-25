import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import ShadowSync
import Synchronization
import Testing

@testable import Memoir

@MainActor
enum FeaturesTesting {
  static func model(_ world: SettingsWorld, effects: MemoirModuleEffects? = nil) async throws -> (FeaturesModel, Task<Void, Never>) {
    try await model(world.context, effects: effects)
  }

  static func model(_ context: MemoirScreenContext, effects: MemoirModuleEffects? = nil) async throws -> (FeaturesModel, Task<Void, Never>) {
    let model = FeaturesModel(context: context, effects: effects)
    let task = Task { await model.run() }
    try await until("the settings") { model.standing.state.value != nil }
    return (model, task)
  }

  static func setModules(_ modules: [MemoirModule: Bool], in context: MemoirScreenContext) async throws {
    try await context.writer.write { _, transaction in
      _ = try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { record in
        for (module, enabled) in modules { record.setModule(module, enabled: enabled) }
      }
    }
  }

  static func activeQuests(in context: MemoirScreenContext) async throws -> Set<UUID> {
    Set(try await context.stores.main.read { transaction in try MemoirDerived.quests(in: transaction) }.filter(\.schedule.active).map(\.id))
  }

  static func pauses(in context: MemoirScreenContext) async throws -> [MemoirCommand] {
    try await context.stores.commands().filter { command in
      guard case .questUpdate = try MemoirCommandBody(command) else { return false }
      return true
    }
  }

  static func effects(environment: HealthEnvironment = LogTesting.environment(), sync: SyncRuntimes? = nil) -> MemoirModuleEffects {
    MemoirModuleEffects(sync: sync ?? SyncRuntimes(identity: .memoir, factory: nil), health: MemoirHealthImports(environment: { environment }))
  }

  static func claim(_ environment: HealthEnvironment, in context: MemoirScreenContext) async throws {
    let device = try #require(environment.device)
    _ = try await context.stores.main.write { transaction in try HealthSettings.claim(device, atMillis: 1, in: &transaction) }
  }

  static func reader(in context: MemoirScreenContext) async throws -> HealthReaderDesignation? {
    try await context.stores.main.read { transaction in try HealthSettings.designation(in: transaction) }
  }

  /// Holds the main store's writer for `seconds` once `held` says so, so a write started meanwhile is still under way when the test acts.
  static func holdWrites(of stores: MemoirStores, for seconds: TimeInterval) -> (task: Task<Void, any Error>, held: @Sendable () -> Bool) {
    let main = stores.main
    let holding = Recorded<Bool>()
    let task = Task.detached {
      _ = try await main.write { _ in
        holding.append(true)
        Thread.sleep(forTimeInterval: seconds)
      }
    }
    return (task, { !holding.values.isEmpty })
  }
}

/// A rates service that answers only once released, recording each question and each one given up when its fill is cancelled.
nonisolated final class HeldRatesClient: RatesClient {
  private let state = Mutex((asked: 0, cancelled: 0, released: false))

  var asked: Int { state.withLock { $0.asked } }
  var cancelled: Int { state.withLock { $0.cancelled } }

  func release() {
    state.withLock { $0.released = true }
  }

  func rates(for pairs: Set<CurrencyPair>, on date: LocalDate) async throws(RatesClientError) -> [CurrencyPair: DecimalText] {
    state.withLock { $0.asked += 1 }
    while !state.withLock({ $0.released }) {
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        state.withLock { $0.cancelled += 1 }
        throw .unavailable("cancelled")
      }
    }
    return Dictionary(uniqueKeysWithValues: pairs.map { ($0, DecimalText("0.1")!) })
  }
}

@MainActor
@Suite("FeaturesModel", TestTimeLimit.standard)
struct FeaturesModelTests {
  @Test("should turn a module off and on through the settings record, with no confirmation")
  func shouldToggleAModule() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }
    #expect(model.isOn(.journal) && model.canChange)

    await model.set(.journal, enabled: false)

    #expect(model.confirmation == nil && model.failure == nil)
    #expect(try await world.record()?.isEnabled(.journal) == false)
    try await until("the read follows") { !model.isOn(.journal) }
    await model.set(.journal, enabled: true)
    #expect(try await world.record()?.isEnabled(.journal) == true)
  }

  @Test("should ask before pausing quests, write nothing until confirmed, and pause them all once it is")
  func shouldConfirmBeforePausingQuests() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let read = try await QuestsTesting.quest("Read", in: world.context)
    let walk = try await QuestsTesting.quest("Walk", in: world.context)
    try await TestClock.until("the quests are active") { try await FeaturesTesting.activeQuests(in: world.context) == [read, walk] }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }

    await model.set(.quests, enabled: false)
    #expect(model.confirmation == FeaturesModel.Confirmation(changes: [.quests: false], pausing: 2))
    #expect(!model.canChange)
    #expect(try await world.record()?.isEnabled(.quests) == true, "asking writes nothing")
    #expect(FeaturesView.pauseTitle(2) == "Pause 2 quests?")
    #expect(FeaturesView.pauseTitle(1) == "Pause 1 quest?")

    model.cancelConfirmation()
    await model.confirm()
    #expect(try await world.record()?.isEnabled(.quests) == true, "a cancelled question changes nothing")
    #expect(try await FeaturesTesting.pauses(in: world.context).isEmpty)

    await model.set(.quests, enabled: false)
    await model.confirm()

    #expect(try await world.record()?.isEnabled(.quests) == false)
    #expect(try await FeaturesTesting.activeQuests(in: world.context).isEmpty)
    let pauses = try await FeaturesTesting.pauses(in: world.context)
    #expect(pauses.count == 2)
    #expect(pauses.allSatisfy { $0.instantMillis == TestClock.millis(day: 0, minute: 720) }, "stamped with the app's clock")
  }

  @Test("should turn Quests off without asking when no quest is active, and never reactivate quests when it comes back on")
  func shouldNotAskWithoutActiveQuests() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }

    await model.set(.quests, enabled: false)
    #expect(model.confirmation == nil)
    #expect(try await world.record()?.isEnabled(.quests) == false)
    let id = try await QuestsTesting.quest("Late", in: world.context)
    await model.set(.quests, enabled: true)
    #expect(try await FeaturesTesting.activeQuests(in: world.context) == [id], "a quest made meanwhile stays as it was")
    #expect(try await FeaturesTesting.pauses(in: world.context).isEmpty)
  }

  @Test("should refuse a change the laws forbid with its copy, and write nothing")
  func shouldShowRefusals() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }
    let before = try await world.record()

    await model.set(.hero, enabled: false)
    #expect(model.failure?.headline == "Quests need Hero. Turn Quests off first.")
    #expect(try await world.record() == before)

    try await FeaturesTesting.setModules([.hero: false, .quests: false, .money: false, .journal: false, .meals: false], in: world.context)
    try await TestClock.until("only Body is left") { model.selection == (try ModuleSelection([.body])) }
    await model.set(.body, enabled: false)
    #expect(model.failure?.headline == "Keep at least one feature on.")
    await model.set(.hero, enabled: true)
    #expect(model.failure?.headline == "Hero needs Quests or Money to be on.")
    #expect(try await world.record()?.isEnabled(.body) == true)
  }

  @Test("should turn Hero on with Quests, and start scoring money from the account's day on the app's clock")
  func shouldBringHeroWithQuests() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    try await FeaturesTesting.setModules([.hero: false, .quests: false, .money: false], in: world.context)
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }

    await model.set(.quests, enabled: true)
    #expect(model.failure == nil)
    #expect(try await world.record()?.isEnabled(.hero) == true)
    #expect(try await world.record()?.isEnabled(.quests) == true)
    #expect(try await world.record()?.moneyScoredFrom == nil, "money is off")

    await model.set(.money, enabled: true)
    #expect(try await world.record()?.moneyScoredFrom == TestClock.day0)
  }

  @Test("should ask for the home currency first in a vault without settings, then offer the features")
  func shouldAskForTheHomeCurrencyFirst() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }
    #expect(model.standing.state.value == .unset)
    #expect(!model.canChange)

    await model.set(.journal, enabled: false)
    #expect(try await world.record() == nil)

    await model.setHomeCurrency(try #require(CurrencyCode("NOK")))
    try await until("the features are offered") { model.canChange }
    #expect(try await world.record()?.defaultCurrency.code == "NOK")
    #expect(FeaturesModel.presented(.settingsAbsent)?.headline == "Choose your home currency first.")
  }

  @Test("should show a failed write through the app's writing errors")
  func shouldPresentAFailedWrite() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let (model, task) = try await FeaturesTesting.model(world)
    defer { task.cancel() }
    task.cancel()
    try world.context.stores.main.close()

    await model.set(.journal, enabled: false)

    #expect(model.failure != nil)
    #expect(model.pending == nil && !model.isSaving)
  }
}

@MainActor
@Suite("Module side effects", TestTimeLimit.standard)
struct MemoirModuleEffectsTests {
  @Test("should enforce Quests off on a return to the foreground, stamped with the app's clock")
  func shouldEnforceOnForeground() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    try await FeaturesTesting.setModules([.quests: false], in: world.context)
    let effects = FeaturesTesting.effects()
    effects.follow(world.opened)
    try await Task.sleep(for: .milliseconds(200))
    await effects.foregrounded()?.value

    let straggler = try await QuestsTesting.quest("From a lagging device", in: world.context)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await FeaturesTesting.activeQuests(in: world.context) == [straggler], "a quest alone is not a settings change")
    world.clock.set(day: 0, minute: 800)

    await effects.foregrounded()?.value

    #expect(try await FeaturesTesting.activeQuests(in: world.context).isEmpty)
    #expect(try await FeaturesTesting.pauses(in: world.context).map(\.instantMillis) == [TestClock.millis(day: 0, minute: 800)])
    effects.follow(nil)
  }

  @Test("should enforce when the modules change, as when a change arrives from another device")
  func shouldEnforceOnSettingsChange() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let quest = try await QuestsTesting.quest("Read", in: world.context)
    let environment = LogTesting.environment()
    try await FeaturesTesting.claim(environment, in: world.context)
    let effects = FeaturesTesting.effects(environment: environment)
    effects.follow(world.opened)
    defer { effects.follow(nil) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await FeaturesTesting.activeQuests(in: world.context) == [quest])

    try await FeaturesTesting.setModules([.quests: false, .body: false], in: world.context)

    try await TestClock.until("the quest is paused") { try await FeaturesTesting.activeQuests(in: world.context).isEmpty }
    try await TestClock.until("the reader is cleared") { try await FeaturesTesting.reader(in: world.context) == nil }
  }

  @Test("should settle nothing for an enforce that ends after the vault changed, and let it finish before stopping")
  func shouldSettleNothingAfterAVaultChange() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let environment = LogTesting.environment()
    try await FeaturesTesting.claim(environment, in: world.context)
    environment.preferences.metrics = [.steps]
    try await FeaturesTesting.setModules([.body: false], in: world.context)
    let effects = FeaturesTesting.effects(environment: environment)
    effects.follow(world.opened)
    try await TestClock.until("the first enforce clears the reader") { try await FeaturesTesting.reader(in: world.context) == nil }
    try await TestClock.until("and forgets the metrics") { environment.preferences.metrics.isEmpty }
    environment.preferences.metrics = [.steps]
    try await FeaturesTesting.claim(environment, in: world.context)
    let held = FeaturesTesting.holdWrites(of: world.context.stores, for: 0.6)
    try await TestClock.until("the writer is held") { held.held() }
    let enforcing = effects.foregrounded()
    try await Task.sleep(for: .milliseconds(150))

    await effects.stop()

    #expect(try await FeaturesTesting.reader(in: world.context) == nil, "the enforce under way finished before stop returned")
    #expect(environment.preferences.metrics == [.steps], "an enforce for a vault no longer followed settles nothing here")
    #expect(effects.foregrounded() == nil)
    await enforcing?.value
    try await held.task.value
  }

  @Test("should log a failed enforce and carry on")
  func shouldSurviveAFailedEnforce() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let effects = FeaturesTesting.effects()
    effects.follow(world.opened)
    try world.opened.stores.main.close()

    await effects.foregrounded()?.value
    await effects.foregrounded()?.value
    effects.follow(nil)
    #expect(effects.foregrounded() == nil, "nothing is followed")
  }

  @Test("should forget what this device read from Health once Body is turned off here, without asking Health")
  func shouldStopReadingWhenBodyTurnsOff() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let source = FakeHealthSource()
    let environment = LogTesting.environment(source: source)
    let reading = HealthReadingModel(environment: environment, stores: world.context.stores, clock: world.context.clock)
    try await QuestsObservation { await reading.observe() }.during {
      await reading.set(.steps, reading: true)
      try await until("this device reads") { reading.isReading(.steps) }
      let asked = source.requested.count
      let effects = FeaturesTesting.effects(environment: environment)
      effects.follow(world.opened)
      defer { effects.follow(nil) }
      let (model, task) = try await FeaturesTesting.model(world, effects: effects)
      defer { task.cancel() }

      await model.set(.body, enabled: false)

      #expect(environment.preferences.metrics.isEmpty)
      #expect(try await FeaturesTesting.reader(in: world.context) == nil)
      try await until("the reading model follows") { reading.reading.isEmpty && !reading.isThisDeviceReader }
      #expect(source.requested.count == asked, "Health is not asked")
    }
  }

  @Test("should reroute sync once Body off takes Activity off iCloud")
  func shouldRerouteWhenActivityLeavesICloud() async throws {
    let world = try MemoirSyncWorld(policy: .iCloud)
    defer { world.remove() }
    let clock = TestClock(day: 0, minute: 720)
    let context = MemoirScreenContext(stores: world.stores, clock: clock.memoir(deviceZone: TestClock.utc))
    try await SettingsModel.createSettings(try #require(CurrencyCode("EUR")), through: context.writer)
    try await world.attach()
    let activity = ActivitySyncModel(main: world.stores.main, sync: world.runtimes)
    await activity.load()
    await activity.set(true)
    #expect(world.routes == ["activity"])
    let opened = MemoirOpenedVault(
      stores: world.stores, projection: try MemoirReconciler(appVersion: "1", now: context.clock.now, deviceZone: { TestClock.utc }), clock: context.clock)
    let effects = FeaturesTesting.effects(sync: world.runtimes)
    effects.follow(opened)
    let (model, task) = try await FeaturesTesting.model(context, effects: effects)

    await model.set(.body, enabled: false)

    #expect(world.routes.isEmpty)
    await activity.load()
    #expect(activity.state == .bodyOff, "Activity on iCloud is not offered while Body is off")
    await activity.set(true)
    #expect(world.routes.isEmpty)
    task.cancel()
    effects.follow(nil)
    await world.runtimes.shutDown()
  }
}

@MainActor
@Suite("Modules in the demo", TestTimeLimit.standard)
struct ModulesDemoTests {
  @Test("should change only the demo's own modules: no enforce, no Health, no sync")
  func shouldKeepTheDemoApart() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    var demo = world.opened
    demo.isDemo = true
    let environment = LogTesting.environment()
    environment.preferences.metrics = [.steps]
    try await FeaturesTesting.claim(environment, in: world.context)
    let effects = FeaturesTesting.effects(environment: environment)
    effects.follow(demo)
    #expect(effects.foregrounded() == nil, "the demo's vault is never followed")
    let imports = MemoirHealthImports(environment: { environment })
    #expect(imports.foregrounded(demo) == nil, "the demo never reads Health")

    let (model, task) = try await FeaturesTesting.model(MemoirScreenContext(demo), effects: effects)
    defer { task.cancel() }
    await model.set(.body, enabled: false)

    #expect(try await world.record()?.isEnabled(.body) == false)
    #expect(environment.preferences.metrics == [.steps], "this device's Health choices are untouched")
  }
}

@MainActor
@Suite("Module gates", TestTimeLimit.standard)
struct ModuleGateTests {
  @Test("should neither import nor ask Health while Body is off, forgetting this device's metrics, and import again once it is on")
  func shouldGateHealthImports() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let source = FakeHealthSource()
    source.setTotal(4_000, of: .stepCount)
    let environment = LogTesting.environment(source: source)
    try await FeaturesTesting.claim(environment, in: world.context)
    environment.preferences.metrics = [.steps]
    try await FeaturesTesting.setModules([.body: false], in: world.context)
    let imports = MemoirHealthImports(environment: { environment })

    await imports.foregrounded(world.opened)?.value

    #expect(source.windows.isEmpty && source.requested.isEmpty)
    #expect(environment.preferences.metrics.isEmpty)
    #expect(imports.foregrounded(world.opened) == nil, "nothing left to read")

    try await FeaturesTesting.setModules([.body: true], in: world.context)
    environment.preferences.metrics = [.steps]
    await imports.foregrounded(world.opened)?.value
    #expect(!source.windows.isEmpty)
  }

  @Test("should ask for no rate while Money is off, and ask once it is on again")
  func shouldGateRates() async throws {
    let context = try await MoneyFixture.context()
    try await FeaturesTesting.setModules([.money: false], in: context)
    let client = RecordingRatesClient()
    let defaults = UserDefaults(suiteName: "ModuleGateTests-\(UUID().uuidString)")!
    let rates = MemoirRates(client: client, setting: RatesDeviceSetting(defaults: defaults), now: TestClock(day: 0, minute: 720).now)
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)
    try await Task.sleep(for: .milliseconds(300))
    #expect(client.requests.isEmpty)

    try await FeaturesTesting.setModules([.money: true], in: context)

    try await TestClock.until("the rate is asked") { !client.requests.isEmpty }
    rates.phaseChanged(isActive: false)
  }

  @Test("should refuse to turn Activity on iCloud on once Body is off, writing nothing")
  func shouldRefuseActivityWhileBodyIsOff() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = ActivitySyncModel(main: world.context.stores.main, sync: SyncRuntimes(identity: .memoir, factory: nil))
    await model.load()
    #expect(model.state == .loaded(isOn: false))
    try await FeaturesTesting.setModules([.body: false], in: world.context)

    await model.set(true)

    #expect(model.state == .bodyOff && model.failure == nil)
    #expect(try await world.context.stores.main.read { transaction in try HealthSettingsRecord.read(key: .healthSettings, in: transaction) } == .absent)
  }

  @Test("should stop a fill under way when Money turns off, recording nothing, and ask again once it is on")
  func shouldStopAFillWhenMoneyTurnsOff() async throws {
    let context = try await MoneyFixture.context()
    let client = HeldRatesClient()
    let defaults = UserDefaults(suiteName: "ModuleGateTests-\(UUID().uuidString)")!
    let rates = MemoirRates(client: client, setting: RatesDeviceSetting(defaults: defaults), now: TestClock(day: 0, minute: 720).now)
    rates.follow(context)
    rates.phaseChanged(isActive: true)
    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)
    try await TestClock.until("the fill asks") { client.asked == 1 }

    try await FeaturesTesting.setModules([.money: false], in: context)

    try await TestClock.until("the fill is given up") { client.cancelled == 1 }
    #expect(try await LogTesting.count(.fxRate, in: context.stores.main) == 0)
    #expect(rates.pacing == RatePacing(), "a fill given up records no pacing")

    try await FeaturesTesting.setModules([.money: true], in: context)
    try await TestClock.until("it asks again") { client.asked == 2 }
    client.release()
    try await TestClock.until("the rate is recorded") { try await LogTesting.count(.fxRate, in: context.stores.main) > 0 }
    rates.phaseChanged(isActive: false)
  }

  @Test("should stop the module effects when the vault is deleted")
  func shouldStopEffectsOnDeletion() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    world.modules.follow(opened)
    #expect(world.modules.foregrounded() != nil)

    try await world.deletion().delete()

    #expect(world.vault.opened?.stores.main !== opened.stores.main)
    #expect(world.modules.foregrounded() == nil, "the deleted vault is no longer followed")
    await world.runtimes.shutDown()
  }

  @Test("should hide the displayed title and intensity without Hero")
  func shouldHideHeroRows() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()
    #expect(model.showsHero)

    try await FeaturesTesting.setModules([.hero: false, .quests: false], in: world.context)

    try await until("the hero rows hide") { !model.showsHero }
  }
}

import Foundation
import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSyncRuntime
import SwiftUI
import Testing

@testable import Memoir

@MainActor
@Suite("Memoir demo", TestTimeLimit.standard)
struct MemoirDemoTests {
  private let root = FileManager.default.temporaryDirectory.appending(path: "MemoirDemoTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var demoDirectory: URL { root.appending(path: DemoDirectory.name, directoryHint: .isDirectory) }
  private var ownerDirectory: URL { root.appending(path: "Vaults", directoryHint: .isDirectory) }

  private func session() -> MemoirDemoSession {
    let directory = demoDirectory
    return MemoirDemoEnvironment.session(directory: { directory }, pace: .zero)
  }

  private func entered() async throws -> (session: MemoirDemoSession, demo: MemoirDemoEnvironment, opened: MemoirOpenedVault) {
    let session = session()
    await session.enter()
    let demo = try #require(session.active)
    return (session, demo, try #require(demo.vault.opened))
  }

  private func owner() async throws -> MemoirOpenedVault {
    try await MemoirVaultOpener.open(.vault(try MemoirVault(directory: ownerDirectory)), appVersion: "1")
  }

  /// Every file under `directory` with its bytes, by path relative to it.
  private func snapshot(_ directory: URL) throws -> [String: Data] {
    let base = directory.standardizedFileURL.path(percentEncoded: false)
    var files: [String: Data] = [:]
    for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      files[String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))] = try Data(contentsOf: url)
    }
    return files
  }

  private func grant(_ requirement: AIConsentRequirement, in store: VaultStore) async throws {
    try await store.write { transaction in
      try AIConsent.decide(
        .granted, provider: DemoModelProvider.host, dataClass: requirement.dataClass, summary: requirement.disclosure, atMillis: 1, in: &transaction)
    }
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

  @Test("should leave the owner's vault byte for byte as it was after entering the demo, writing in it and leaving")
  func shouldNeverTouchTheOwnersVault() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = try await owner()
    let quest = UUID()
    let schedule = try QuestSchedule(
      strictness: .routine, startTimeMinutes: 480, durationMinutes: 30, statAffinity: .body,
      recurrence: try RecurrenceRule(frequency: .daily, startDate: try await MemoirScreenContext(owner).today().date))
    try await MemoirScreenContext(owner).writer.issue(
      .questCreate(QuestCreation(questId: quest, schedule: schedule)), creating: QuestRecord(id: quest, name: "The owner's lighthouse watch"))
    let before = try snapshot(ownerDirectory)

    let (session, _, opened) = try await entered()
    let demoContext = MemoirScreenContext(opened)
    try await demoContext.writer.issue(.questComplete(Occurrence(quest: MemoirDemo.walk, date: try await demoContext.today().date)))
    try await grant(InsightConsent.call, in: opened.stores.main)
    try await grant(ReceiptStructuring.consent, in: opened.stores.main)
    await session.leave()

    #expect(try snapshot(ownerDirectory) == before)
    #expect(!before.isEmpty)
    #expect(try await owner.stores.main.read { transaction in try QuestRecord.listing(in: transaction).entries.map(\.record.name) } == ["The owner's lighthouse watch"])
    #expect(try await owner.stores.main.read { transaction in try Ledger.entries(in: transaction) }.isEmpty)
    #expect(!exists(demoDirectory))
  }

  @Test("should open the demo in its own directory with the sample week, a subscription and no sync")
  func shouldOpenASeededDemo() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, demo, opened) = try await entered()

    #expect(exists(demoDirectory.appending(path: "Default/vault.sqlite")))
    #expect(try await MemoirDemo.isSeeded(opened.stores))
    let book = try await opened.stores.main.read { transaction in try MoneyBook.load(from: transaction) }
    #expect(book.subscriptions.map(\.name).sorted() == ["Cloud storage", "Music streaming"])
    #expect(!book.expenses.isEmpty)
    #expect(demo.ai.isDemo && demo.ai.hasUsableProvider)
    #expect(demo.sync.status == .off && demo.sync.runtime == nil)
    #expect(ConsentDisclosure.memoirDemo.map(\.requirement) == ConsentDisclosure.memoir.map(\.requirement))
    #expect(MemoirScreenContext(opened).isDemo)
    #expect(HealthReadingModel(context: MemoirScreenContext(opened)).availability == .demo)
    await session.leave()
    #expect(!exists(demoDirectory))
  }

  @Test("should answer an insight in the demo, with its consent and its call ledgered in the demo's own store")
  func shouldAnswerAnInsightInTheDemo() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = try await owner()
    let (session, demo, opened) = try await entered()
    try await grant(InsightConsent.call, in: opened.stores.main)
    let access = try #require(demo.insights.access(for: MemoirScreenContext(opened)))

    #expect(await access.isProviderReady())
    guard case .started(let handle) = try await access.engine.ask("How did my week go?", id: UUID()) else {
      Issue.record("the question did not start")
      return
    }

    #expect(await handle.result == .settled(.succeeded))
    let result = try #require(try await InsightResults.listing(in: opened.stores).first)
    #expect(!result.answer.isEmpty)
    let ledger = try await opened.stores.main.read { transaction in try Ledger.entries(in: transaction) }
    #expect(!ledger.isEmpty && ledger.allSatisfy(\.isDemo))
    #expect(try await owner.stores.main.read { transaction in try Ledger.entries(in: transaction) }.isEmpty)
    await session.leave()
  }

  @Test("should script a receipt reply the receipt schema accepts, read as the expense form reads it")
  func shouldReadAReceiptInTheDemo() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let reply = try #require(DemoRule.memoirReceipt.replies.first)
    guard case .json(let value) = reply else {
      Issue.record("the receipt reply is not JSON")
      return
    }
    #expect(StructuredSchema.validate(CanonicalJSON.encode(value), against: ReceiptStructuring.schema).isEmpty)

    let (session, demo, opened) = try await entered()
    try await grant(ReceiptStructuring.consent, in: opened.stores.main)
    let reading = try await ReceiptStructuring.read("HARBOUR ST BAKERY\nTOTAL 14.80", router: demo.ai.router(store: opened.stores.main))

    #expect(reading.amount == "14.80")
    #expect(reading.merchant == "Harbour Street Bakery")
    #expect(reading.category == CategoryKey("food"))
    #expect(!reading.needsReview)
    await session.leave()
  }

  @Test("should enter the demo when launched with its argument, and only then")
  func shouldEnterWithTheLaunchArgument() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = session()
    await plain.launched(arguments: ["Memoir"])
    #expect(plain.isOff)

    let launched = session()
    await launched.launched(arguments: ["Memoir", DemoDirectory.launchArgument])

    let demo = try #require(launched.active)
    #expect(try await MemoirDemo.isSeeded(try #require(demo.vault.opened).stores))
    await launched.leave()
    #expect(launched.isOff)
    #expect(!exists(demoDirectory))
  }
}

@MainActor
@Suite("Memoir window runtimes", TestTimeLimit.standard)
struct MemoirWindowRuntimesTests {
  private final class Followed {
    var synced: [ObjectIdentifier] = []
    var foregrounded = 0
  }

  private let root = FileManager.default.temporaryDirectory.appending(path: "MemoirWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func windows(_ followed: Followed) throws -> MemoirWindowRuntimes {
    let vault = MemoirVaultModel(
      open: { _ throws(VaultOpenError) in
        do throws(MemoirVaultOpenError) {
          return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
        } catch {
          throw error.vaultOpenError
        }
      }, hasUnlockedSinceBoot: { true })
    let ai = AIServices.memoir(defaults: try #require(UserDefaults(suiteName: "MemoirWindowTests-\(UUID().uuidString)")))
    let sync = SyncRuntimes(identity: .memoir) { synced, _ in
      followed.synced.append(ObjectIdentifier(synced.store))
      return nil
    }
    let owner = MemoirRuntimeSet(vault: vault, ai: ai, sync: sync, insights: MemoirInsights(ai: ai, trustedClock: vault.trustedClock), dayTurns: MemoirDayTurns())
    let directory = root.appending(path: DemoDirectory.name, directoryHint: .isDirectory)
    return MemoirWindowRuntimes(
      owner: owner, demo: MemoirDemoEnvironment.session(directory: { directory }, pace: .zero),
      ownerVaultChanged: {
        owner.dayTurns.follow(vault.opened)
        guard let opened = vault.opened else { return }
        await sync.launch(MemoirSyncRoutes.vault(opened.stores), trustedClock: vault.trustedClock)
        await owner.insights.follow(opened)
      },
      ownerForegrounded: { followed.foregrounded += 1 })
  }

  @Test("should keep the owner's sync and insights on the owner's vault while the demo runs, hand them every scene phase, and give the window back")
  func shouldKeepTheOwnersRuntimesOnTheirVault() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let followed = Followed()
    let windows = try windows(followed)
    let owner = windows.owner
    await owner.vault.open()
    await windows.activeVaultChanged()
    let ownerVault = try #require(owner.vault.opened)
    #expect(followed.foregrounded == 1)

    await windows.demo.enter()
    let demo = try #require(windows.demo.active)
    #expect(windows.active.vault === demo.vault)
    await windows.activeVaultChanged()
    let demoVault = try #require(demo.vault.opened)

    #expect(followed.synced == [ObjectIdentifier(ownerVault.stores.main)])
    #expect(followed.foregrounded == 1)
    #expect(owner.insights.access(for: MemoirScreenContext(ownerVault)) != nil)
    #expect(owner.insights.access(for: MemoirScreenContext(demoVault)) == nil)
    #expect(demo.insights.access(for: MemoirScreenContext(demoVault)) != nil)

    await windows.phaseChanged(.background)
    #expect(!owner.insights.isActive)
    #expect(!demo.insights.isActive)
    await windows.phaseChanged(.active)
    #expect(owner.insights.isActive)
    #expect(demo.insights.isActive)
    #expect(followed.foregrounded == 2)

    await windows.demo.leave()
    #expect(windows.active.vault === owner.vault)
    #expect(windows.active.insights === owner.insights)
    #expect(followed.synced == [ObjectIdentifier(ownerVault.stores.main)])
  }

  @Test("should offer the demo on onboarding's first step, enter it without writing the owner's settings or first quest, and return to onboarding on leaving")
  func shouldEnterTheDemoFromOnboarding() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = try windows(Followed())
    let owner = windows.owner
    await owner.vault.open()
    await windows.activeVaultChanged()
    let ownerVault = try #require(owner.vault.opened)
    let gate = OnboardingGate()
    let watching = Task { await gate.run(stores: ownerVault.stores) }
    defer { watching.cancel() }
    try await until("onboarding") { gate.state == .needed }
    let onboarding = OnboardingModel(context: MemoirScreenContext(ownerVault))
    #expect(onboarding.offersDemo)
    onboarding.advance()
    onboarding.setName("Morning walk")
    #expect(onboarding.step == .quest && !onboarding.offersDemo)
    onboarding.back()
    #expect(onboarding.offersDemo)

    await windows.demo.enter()
    #expect(windows.active.vault !== owner.vault)
    await windows.activeVaultChanged()
    await windows.demo.leave()

    #expect(windows.active.vault === owner.vault)
    #expect(gate.state == .needed)
    #expect(try await ownerVault.stores.main.read { transaction in try OnboardingStanding.isNeeded(in: transaction) })
    #expect(try await ownerVault.stores.main.read { transaction in try QuestRecord.listing(in: transaction).entries.isEmpty })
    let returning = OnboardingGate()
    let rewatching = Task { await returning.run(stores: ownerVault.stores) }
    defer { rewatching.cancel() }
    try await until("onboarding again") { returning.state == .needed }
    #expect(OnboardingModel(context: MemoirScreenContext(ownerVault)).offersDemo)
  }

  @Test("should keep the demo's device choices in the demo's own defaults, never the owner's, and empty them on leaving")
  func shouldKeepTheDemosChoicesOutOfTheOwnersDefaults() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = [ComingBackDismissal.key, WithdrawalAcknowledgements.key, WeightUnitPreference.key, HealthPreferences.key]
    let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
    let directory = root.appending(path: DemoDirectory.name, directoryHint: .isDirectory)
    let session = MemoirDemoEnvironment.session(directory: { directory }, pace: .zero)
    await session.enter()
    let context = MemoirScreenContext(try #require(session.active?.vault.opened))
    let suite = DemoDefaults.suite(for: .memoir)
    let day = try await context.today().date
    let withdrawn = UUID()

    ComingBackDismissal(defaults: context.defaults).dismiss(on: day)
    WithdrawalAcknowledgements(defaults: context.defaults).acknowledge([withdrawn])
    let weight = WeightModel(context: context)
    weight.unit = weight.unit == .pounds ? .kilograms : .pounds
    HealthEnvironment.demo.preferences.metrics = [.steps]

    #expect(ComingBackModel(context: context).dismissal.isDismissed(on: day))
    #expect(HeroModel(context: context).acknowledged.contains(withdrawn))
    #expect(suite.string(forKey: WeightUnitPreference.key) == weight.unit.rawValue)
    #expect(suite.stringArray(forKey: HealthPreferences.key) == [BuiltinMetric.steps.rawValue])
    #expect(keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == before)
    await session.leave()
    #expect(keys.allSatisfy { suite.object(forKey: $0) == nil })
  }
}

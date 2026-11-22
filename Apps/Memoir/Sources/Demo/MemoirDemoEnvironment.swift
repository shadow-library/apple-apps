import Foundation
import MemoirCore
import OSLog
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowStore

typealias MemoirDemoSession = DemoSession<MemoirDemoEnvironment>

/// What the demo runs on in place of the owner's: its own vault in the demo's directory with the sample week, `AIServices.demo`, a sync that never
/// attaches, and its own day turns and insights. No reminder is scheduled and Health is never read for it.
final class MemoirDemoEnvironment {
  let vault: MemoirVaultModel
  let ai: AIServices
  let sync: SyncRuntimes
  let dayTurns: MemoirDayTurns
  let insights: MemoirInsights

  init(directory: URL, deviceZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }, locale: Locale = .current, pace: Duration = DemoModelProvider.readingPace) {
    let currency = SettingsCurrencies.standard(for: locale)
    vault = MemoirVaultModel { wallClock throws(VaultOpenError) in
      do throws(MemoirVaultOpenError) {
        return try await Self.open(directory, clock: MemoirClock(now: wallClock, deviceZone: deviceZone), currency: currency)
      } catch {
        throw error.vaultOpenError
      }
    }
    ai = .memoirDemo(pace: pace)
    sync = SyncRuntimes(identity: .memoir, factory: nil)
    dayTurns = MemoirDayTurns()
    insights = MemoirInsights(ai: ai, trustedClock: vault.trustedClock)
  }

  var runtimes: MemoirRuntimeSet { MemoirRuntimeSet(vault: vault, ai: ai, sync: sync, insights: insights, dayTurns: dayTurns) }

  static func session(directory: @escaping MemoirDemoSession.Locate = DemoDirectory.appLocation, pace: Duration = DemoModelProvider.readingPace) -> MemoirDemoSession {
    MemoirDemoSession(
      directory: directory, defaultsSuite: DemoDefaults.suiteName(for: .memoir),
      start: { directory in
        let demo = MemoirDemoEnvironment(directory: directory, pace: pace)
        await demo.vault.open()
        await demo.vaultChanged()
        return demo
      },
      stop: { demo in await demo.close() })
  }

  /// The demo is entered from the screen, so its insights start in the foreground.
  func vaultChanged() async {
    dayTurns.follow(vault.opened)
    await insights.phaseChanged(isActive: true)
    await insights.follow(vault.opened)
  }

  func close() async {
    dayTurns.follow(nil)
    await insights.follow(nil)
    guard let stores = vault.opened?.stores else { return }
    for kind in MemoirStoreKind.allCases {
      do {
        try stores.store(kind).close()
      } catch {
        Self.logger.notice("A demo store was still in use as it closed code=\(error.code, privacy: .public)")
      }
    }
  }

  @concurrent
  nonisolated private static func open(_ directory: URL, clock: MemoirClock, currency: CurrencyCode) async throws(MemoirVaultOpenError) -> MemoirOpenedVault {
    let vault: MemoirVault
    do {
      vault = try MemoirVault(directory: directory)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
    var opened = try await MemoirVaultOpener.open(.vault(vault), appVersion: try MemoirVaultOpener.buildVersion(), clock: clock)
    opened.isDemo = true
    do {
      guard try await !MemoirDemo.isSeeded(opened.stores) else { return opened }
      try await MemoirDemo.seed(opened.stores, now: clock.now(), zone: clock.deviceZone(), currency: currency)
      try await MemoirDemoSubscriptions.create(in: MemoirScreenContext(opened), currency: currency)
      try await opened.refreshDay()
    } catch {
      throw .openFailed(error.localizedDescription)
    }
    return opened
  }

  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "demo") }
}

/// The demo's two subscriptions, written as the Money screens write them.
nonisolated enum MemoirDemoSubscriptions {
  static func create(in context: MemoirScreenContext, currency: CurrencyCode) async throws {
    let today = try await context.today().date
    guard let subs = CategoryKey("subs"), let soon = today.adding(days: 9), let later = today.adding(days: 64) else { return }
    let subscriptions = [
      SubscriptionRecord(
        id: UUID.v7(), name: "Music streaming", amountMinor: 1_099, currency: currency, frequency: .known(.monthly), billingDay: soon.day, anchorOn: soon,
        category: subs),
      SubscriptionRecord(
        id: UUID.v7(), name: "Cloud storage", amountMinor: 2_999, currency: currency, frequency: .known(.yearly), billingDay: later.day, anchorOn: later,
        category: subs),
    ]
    try await context.writer.write { issuer, transaction in
      for subscription in subscriptions { try SubscriptionWrites.create(subscription, issuer: issuer, in: &transaction) }
    }
  }
}

extension ConsentDisclosure {
  /// The owner's disclosures under the same ids, saying what the demo does with each: nothing leaves the device.
  nonisolated static let memoirDemo = memoir.map { disclosure in
    ConsentDisclosure(
      id: disclosure.id, dataClass: disclosure.dataClass, title: { disclosure.title },
      explanation: { _ in
        String(localized: "In the demo, answers come from a script on this device and use only the sample data. Nothing is sent anywhere.", table: "Demo")
      })
  }
}

extension DemoRule {
  /// A receipt read in the demo always gives the same bakery total; its currency, category and date are left to the form.
  nonisolated static let memoirReceipt = DemoRule(
    DemoMatch(schema: ReceiptStructuring.schemaName),
    replies: [.json(["amount": "14.80", "currency": .null, "merchant": "Harbour Street Bakery", "category": "food", "date": .null, "confidence": 1])])
}

extension AIServices {
  static func memoirDemo(pace: Duration = DemoModelProvider.readingPace) -> AIServices {
    demo(
      identity: .memoir, script: DemoScript(rules: MemoirDemo.insightRules + [.memoirReceipt], fallback: MemoirDemo.fallback), disclosures: ConsentDisclosure.memoirDemo,
      requestGuard: { _ in nil }, pace: pace)
  }
}

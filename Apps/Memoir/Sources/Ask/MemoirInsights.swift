import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore

/// What the Ask screen and the foreground hook run insights through: the vault's one `InsightEngine` (one runner per vault keeps a second attempt of a
/// job from starting on this device), its router, whether a provider key is there to call with, and the settler that prices calls left pending
/// (a cancelled call, or an OpenRouter figure that had not arrived), which otherwise stay out of the spend and its caps.
nonisolated struct InsightAccess: Sendable {
  let engine: InsightEngine
  let router: InsightEngine.RouterSource
  let hasKey: @Sendable () async -> Bool
  let leases: LeaseClock
  let settler: CostSettler?

  /// Prices what the attempt left pending once it ends.
  func settle(after handle: AttemptHandle) async {
    _ = await handle.result
    await settler?.settle()
  }
}

/// Owns the open vault's insight engine and its cost settler for the life of the process. Insights start only while the app is in the foreground: the
/// first time a vault is in the foreground the engine resumes this device's interrupted attempts, and at every return to the foreground the standing
/// question's due night runs, on whichever device is open.
@MainActor
@Observable
final class MemoirInsights {
  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "insights") }

  private let makeAccess: (MemoirOpenedVault) -> InsightAccess
  private var vault: MemoirOpenedVault?
  private(set) var access: InsightAccess?
  private var foregroundRun: Task<Void, Never>?
  private var resumed = false
  private var isActive = false

  convenience init(ai: AIServices, trustedClock: TrustedClock?) {
    self.init { opened in Self.access(stores: opened.stores, clock: opened.clock, ai: ai, trustedClock: trustedClock) }
  }

  init(makeAccess: @escaping (MemoirOpenedVault) -> InsightAccess) {
    self.makeAccess = makeAccess
  }

  /// The engine of the vault whose stores `context` holds; nil when the screen's vault is not the one followed.
  func access(for context: MemoirScreenContext) -> InsightAccess? {
    guard let vault, vault.stores.main === context.stores.main else { return nil }
    return access
  }

  /// Builds the engine for a newly opened vault, and runs it at once when the app is in the foreground; keeps following a vault already followed.
  func follow(_ opened: MemoirOpenedVault?) async {
    guard let opened else {
      access?.settler?.shutDown()
      vault = nil
      access = nil
      return
    }
    if let vault, vault.stores.main === opened.stores.main { return }
    access?.settler?.shutDown()
    vault = opened
    resumed = false
    let made = makeAccess(opened)
    access = made
    made.settler?.settleLeftovers()
    await foreground()
  }

  /// Insights run only in the foreground: a launch or a wake for a push in the background builds the engine and runs nothing.
  func phaseChanged(isActive: Bool) async {
    self.isActive = isActive
    await foreground()
  }

  /// Resumes this device's interrupted attempts once per vault, then runs the standing question's due night; a run already under way is not asked again.
  private func foreground() async {
    guard isActive, let vault, let access, foregroundRun == nil else { return }
    let resume = !resumed
    resumed = true
    let task = Task { await Self.runForeground(access: access, vault: vault, resume: resume) }
    foregroundRun = task
    await task.value
    foregroundRun = nil
  }

  static func access(stores: MemoirStores, clock: MemoirClock, ai: AIServices, trustedClock: TrustedClock?) -> InsightAccess {
    let main = stores.main
    let leases = LeaseClock(trusted: trustedClock, device: clock.now)
    let router: InsightEngine.RouterSource = { await ai.router(store: main) }
    let engine = InsightEngine(
      stores: stores, replay: ProjectionInsightReplay(main: main, now: clock.now, deviceZone: clock.deviceZone), router: router, clock: leases)
    return InsightAccess(engine: engine, router: router, hasKey: { await ai.hasProviderKey }, leases: leases, settler: ai.settler(for: main))
  }

  /// Waits for what it started, then prices the calls those attempts left pending.
  nonisolated static func runForeground(access: InsightAccess, vault: MemoirOpenedVault, resume: Bool) async {
    var started: [AttemptHandle] = []
    if resume {
      do {
        started = try await access.engine.resumeInterrupted()
      } catch {
        logger.error("Interrupted insights could not be resumed code=\(error.code, privacy: .public)")
      }
    }
    do {
      if await access.hasKey() {
        let zone = try await AccountZone.load(from: vault.stores.main)
        let local = try vault.clock.localNow(in: zone)
        if case .started(let handle) = try await access.engine.runDue(at: local) { started.append(handle) }
      }
    } catch {
      logger.error("The standing question could not run code=\(error.code, privacy: .public)")
    }
    for handle in started { _ = await handle.result }
    await access.settler?.settle()
  }
}

extension AIServices {
  var hasProviderKey: Bool { (try? keys.contains(settings.provider)) == true }
}

extension MemoirClock {
  /// The account's date and minute now, in the clock in force, as `runDue` and a schedule's `setAt` take them.
  nonisolated func localNow(in zone: AccountZone) throws(CalendarError) -> ZonedFields {
    try resolve(zone).clock.zonedFields(at: Self.millis(now()))
  }
}

extension Error {
  nonisolated fileprivate var code: String { (self as? any ShadowError)?.code ?? "unknown" }
}

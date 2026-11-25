import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// "Fetch exchange rates": kept on this device, on until the owner turns it off here.
struct RatesDeviceSetting {
  static let key = "\(AppIdentity.memoir.id).rates.fetch"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isOn: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

  func set(_ isOn: Bool) {
    defaults.set(isOn, forKey: Self.key)
  }
}

/// When the rates service is asked again, and for what. A pair and date not yet asked is asked at once; one the service had no final rate for is asked
/// again an hour after it was last asked; one a fill deferred past `RateFiller.maximumDates` counts as not asked. After a failure nothing is asked
/// until a backoff from one minute, doubling up to an hour, has passed.
nonisolated struct RatePacing: Sendable, Equatable {
  enum Decision: Equatable {
    case idle
    case run(asking: Set<DatedPair>)
    case wait(until: Date)
  }

  static let firstRetry: TimeInterval = 60
  static let longestRetry: TimeInterval = 3_600
  static let recheck: TimeInterval = 3_600

  private(set) var asked: [DatedPair: Date] = [:]
  private(set) var failedAt: Date?
  private(set) var failures = 0

  func decide(_ requests: RateRequests, now: Date) -> Decision {
    guard !requests.isEmpty else { return .idle }
    if failures > 0, let failedAt {
      let retry = failedAt.addingTimeInterval(min(Self.firstRetry * pow(2, Double(failures - 1)), Self.longestRetry))
      if now < retry { return .wait(until: retry) }
    }
    let dated = requests.dated
    let due = dated.filter { pair in asked[pair].map { now >= $0.addingTimeInterval(Self.recheck) } ?? true }
    if !due.isEmpty || dated.isEmpty { return .run(asking: due) }
    guard let next = dated.compactMap({ asked[$0]?.addingTimeInterval(Self.recheck) }).min() else { return .run(asking: due) }
    return .wait(until: next)
  }

  mutating func ran(_ requests: RateRequests, asking: Set<DatedPair>, at instant: Date, report: RateFillReport?) {
    let current = requests.dated
    asked = asked.filter { current.contains($0.key) }
    let unasked = Set(report.map { $0.deferredDates + $0.failedDates } ?? Array(requests.dates.keys))
    for pair in asking where !unasked.contains(pair.date) { asked[pair] = instant }
    let failed = report.map { !$0.failedDates.isEmpty } ?? true
    failures = failed ? failures + 1 : 0
    failedAt = failed ? instant : nil
  }
}

/// Fills the owner's vault's missing exchange rates through `RateFiller`, only while the app is in the foreground, "Fetch exchange rates" is on and the
/// vault shows Money, never for the demo; Money turned off stops a fill under way and asks nothing until it is on again. It follows what a fill would
/// ask for, so a foreign expense or subscription saved here or synced in is asked about at once, and it paces itself through `RatePacing`; a fill runs
/// off the main actor and never blocks a screen.
@MainActor
@Observable
final class MemoirRates {
  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "rates") }

  private(set) var isFetching: Bool
  @ObservationIgnored private let filler: RateFiller
  @ObservationIgnored private let setting: RatesDeviceSetting
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
  @ObservationIgnored private var context: MemoirScreenContext?
  @ObservationIgnored private var isActive = false
  @ObservationIgnored private var observing: Task<Void, Never>?
  @ObservationIgnored private var filling: Task<Void, Never>?
  @ObservationIgnored private var waiting: Task<Void, Never>?
  @ObservationIgnored private var latest: Observed?
  @ObservationIgnored private(set) var pacing = RatePacing()

  init(
    client: any RatesClient, setting: RatesDeviceSetting = RatesDeviceSetting(), maximumDates: Int = RateFiller.defaultMaximumDates,
    now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  ) {
    filler = RateFiller(client: client, maximumDates: maximumDates)
    self.setting = setting
    self.now = now
    self.sleep = sleep
    isFetching = setting.isOn
  }

  static func live() -> MemoirRates {
    MemoirRates(client: FrankfurterRatesClient())
  }

  /// Follows the owner's vault; a demo's is never followed, and nil stops.
  func follow(_ context: MemoirScreenContext?) {
    guard let context, !context.isDemo else {
      self.context = nil
      return restart()
    }
    if let current = self.context, current.stores.main === context.stores.main { return }
    self.context = context
    pacing = RatePacing()
    restart()
  }

  func phaseChanged(isActive: Bool) {
    guard isActive != self.isActive else { return }
    self.isActive = isActive
    restart()
  }

  func setFetching(_ isOn: Bool) {
    setting.set(isOn)
    isFetching = isOn
    restart()
  }

  /// This device's defaults were cleared with the vault, so the setting is back to its default.
  func deviceSettingCleared() {
    isFetching = setting.isOn
    restart()
  }

  private func restart() {
    observing?.cancel()
    filling?.cancel()
    waiting?.cancel()
    observing = nil
    filling = nil
    waiting = nil
    latest = nil
    guard isActive, isFetching, let context else { return }
    let reads = Self.observe(context)
    observing = Task { [weak self] in
      do {
        for try await observed in reads {
          guard let self, !Task.isCancelled else { return }
          self.latest = observed
          if observed.showsMoney { self.pump() } else { self.pause() }
        }
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.error("Exchange rates stopped following the vault code=\(error.code, privacy: .public)")
      }
    }
  }

  private func pause() {
    filling?.cancel()
    waiting?.cancel()
    filling = nil
    waiting = nil
  }

  private func pump() {
    guard filling == nil, let latest, latest.showsMoney, let context else { return }
    waiting?.cancel()
    waiting = nil
    switch pacing.decide(latest.requests, now: now()) {
    case .idle:
      return
    case .wait(let until):
      let delay = until.timeIntervalSince(now())
      let sleep = sleep
      waiting = Task { [weak self] in
        do {
          try await sleep(delay)
        } catch {
          return
        }
        self?.waiting = nil
        self?.pump()
      }
    case .run(let asking):
      let started = now()
      let filler = filler
      filling = Task { [weak self] in
        let report = await Self.fill(filler, store: context.stores.main, today: latest.today, asking: asking)
        guard let self, !Task.isCancelled else { return }
        self.pacing.ran(latest.requests, asking: asking, at: started, report: report)
        self.filling = nil
        self.pump()
      }
    }
  }

  @concurrent
  nonisolated private static func fill(_ filler: RateFiller, store: VaultStore, today: LocalDate, asking: Set<DatedPair>) async -> RateFillReport? {
    do {
      let report = try await filler.fill(store, today: today, asking: asking)
      if !report.failedDates.isEmpty { logger.notice("The rates service failed dates=\(report.failedDates.count)") }
      return report
    } catch {
      logger.error("The exchange rates could not be filled code=\(error.code, privacy: .public)")
      return nil
    }
  }

  nonisolated private static func observe(_ context: MemoirScreenContext) -> AsyncThrowingStream<Observed, any Error> {
    let clock = context.clock
    return context.stores.main.observeReads { transaction in
      let today = try clock.today(in: try AccountZone.load(in: transaction)).date
      guard try MemoirModules.selection(in: transaction).contains(.money) else { return Observed(today: today, requests: .none, showsMoney: false) }
      return Observed(today: today, requests: try RateFiller.requests(in: transaction, today: today), showsMoney: true)
    }
  }

  nonisolated struct Observed: Sendable, Equatable {
    let today: LocalDate
    let requests: RateRequests
    let showsMoney: Bool
  }
}

extension Error {
  nonisolated fileprivate var code: String { (self as? any ShadowError)?.code ?? "unknown" }
}

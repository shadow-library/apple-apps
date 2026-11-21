import Foundation
import ShadowCore
import ShadowStore

public struct HealthImportReport: Sendable, Equatable {
  public var changedDays: [BuiltinMetric: [LocalDate]] = [:]
  public var unreadableDays = 0
  public var skippedSamples = 0
  public var failed: [BuiltinMetric: HealthReadError] = [:]

  public init() {}
}

/// Fills the built-in metrics' days from Health on the vault's designated reader, one summary per metric and day under the (metric, date) key, so a second
/// reader writes the same records rather than new ones and a repeated read writes nothing. Totals are read for each of the last `days` local days, whose
/// windows come from `clock`, which should be the account's zone in force; samples carry the offset they were recorded at and are dated by it. A day
/// whose samples were all deleted in Health, or whose total is gone, loses its imported value; the owner's own entry is never touched. Imports append no
/// command: metrics never move hero state.
///
/// A device that takes over starts without an index or anchors. Its first read of a total writes only the days Health has a total for, so days the new
/// reader's Health lacks keep what the previous reader imported; its first read of samples reaches back to the earliest day imported for the metric
/// (at most `firstReadLimitDays`), so later deletions of those samples are seen. Deletions of samples older than that, made before the takeover, stay
/// unseen and their days keep their values.
public struct HealthImport: Sendable {
  public static let defaultDays = 7

  /// A first read starts a day before the first window, so a night that began the evening before, or a sample dated by an offset east of the account's
  /// zone, still reaches its day.
  static let sampleLeadMillis: Int64 = 86_400_000
  public static let firstReadLimitDays = 366

  public let reader: any HealthReader
  public let stores: MemoirStores
  public let device: HealthReaderDevice
  public let clock: IssueClock
  private let wallClock: @Sendable () -> Date

  public init(reader: any HealthReader, stores: MemoirStores, device: HealthReaderDevice, clock: IssueClock, wallClock: @escaping @Sendable () -> Date = { Date() }) {
    self.reader = reader
    self.stores = stores
    self.device = device
    self.clock = clock
    self.wallClock = wallClock
  }

  /// Throws `notReader` on any device but the designated one, after clearing what this device had indexed.
  public func run(_ metrics: [BuiltinMetric] = BuiltinMetric.allCases, days: Int = defaultDays) async throws(MetricsError) -> HealthImportReport {
    let designation = try await metricsCall { () async throws(StoreError) in try await stores.main.read { transaction in try HealthSettings.designation(in: transaction) } }
    guard let designation, designation.device == device.id else {
      try await Self.forgetLocalState(in: stores)
      throw .notReader(designation)
    }
    let windows = try windows(days: max(days, 1))
    var report = HealthImportReport()
    for metric in metrics {
      switch metric.healthSource {
      case .total(let quantity):
        try await importTotals(quantity, as: metric, windows: windows, into: &report, metric.syncClass.metricClass)
      case .samples(let kind):
        try await importSamples(kind, as: metric, windows: windows, into: &report, metric.syncClass.metricClass)
      }
    }
    return report
  }

  /// Clears this device's sample index and anchors in the activity and restricted stores; the synced days stay.
  public static func forgetLocalState(in stores: MemoirStores) async throws(MetricsError) {
    for store in [stores.activity, stores.restricted] {
      try await metricsCall { () async throws(StoreError) in try await store.write { transaction in try HealthSampleIndex.forget(in: transaction.database) } }
    }
  }

  private func windows(days: Int) throws(MetricsError) -> [HealthWindow] {
    do throws(CalendarError) {
      guard let now = Int64(exactly: (wallClock().timeIntervalSince1970 * 1000).rounded(.down)) else { throw .dateOutOfRange }
      let today = try clock.localDate(at: now)
      var windows = [HealthWindow]()
      for back in (0..<days).reversed() {
        guard let date = today.adding(days: -back) else { throw .dateOutOfRange }
        windows.append(try HealthWindow(date, in: clock))
      }
      return windows
    } catch {
      throw .calendar(error)
    }
  }

  private func importTotals<Class: MetricClass>(
    _ quantity: HealthTotal, as metric: BuiltinMetric, windows: [HealthWindow], into report: inout HealthImportReport, _: Class.Type
  ) async throws(MetricsError) {
    let totals: [LocalDate: DecimalText]
    do throws(HealthReadError) {
      totals = try await reader.totals(of: quantity, in: windows)
    } catch {
      report.failed[metric] = error
      return
    }
    let id = MetricID<Class>(recordUUID: metric.id)
    let dates = windows.map(\.date)
    let outcome = try await metricsCall { () async throws(StoreError) in
      try await stores.store(of: Class.syncClass).write { transaction in
        let database = transaction.database
        let clearsMissing = try HealthSampleIndex.hasRead(quantity, in: database)
        let outcome = try Self.write(clearsMissing ? dates : dates.filter { totals[$0] != nil }, of: id, in: &transaction) { date in totals[date] }
        try HealthSampleIndex.markRead(quantity, in: database)
        return outcome
      }
    }
    report.add(outcome, for: metric)
  }

  private func importSamples<Class: MetricClass>(
    _ kind: HealthSampleKind, as metric: BuiltinMetric, windows: [HealthWindow], into report: inout HealthImportReport, _: Class.Type
  ) async throws(MetricsError) {
    let store = stores.store(of: Class.syncClass)
    let id = MetricID<Class>(recordUUID: metric.id)
    let start: (anchor: HealthAnchor?, earliest: LocalDate?) = try await metricsCall { () async throws(StoreError) in
      try await store.read { transaction -> (anchor: HealthAnchor?, earliest: LocalDate?) in
        if let anchor = try HealthSampleIndex.anchor(of: kind, in: transaction.database) { return (anchor, nil) }
        let days = try MetricDayRecord<Class>.listing(in: transaction).entries.map(\.record)
        return (nil, days.filter { $0.metric == id && $0.imported != nil }.map(\.date).min())
      }
    }
    let anchor = start.anchor
    let earliest = start.earliest
    let startMillis = try firstReadStart(windows: windows, earliest: earliest)
    let changes: HealthSampleChanges
    do throws(HealthReadError) {
      changes = try await reader.changes(of: kind, after: anchor, since: startMillis)
    } catch {
      report.failed[metric] = error
      return
    }
    let (outcome, skipped) = try await metricsCall { () async throws(StoreError) in
      try await store.write { transaction in
        let applied = try HealthSampleIndex.apply(changes, of: kind, in: transaction.database)
        let database = transaction.database
        let outcome = try Self.write(applied.days.sorted(), of: id, in: &transaction) { date in try HealthSampleIndex.summary(of: kind, on: date, in: database) }
        return (outcome, applied.skipped)
      }
    }
    report.add(outcome, for: metric)
    report.skippedSamples += skipped
  }

  private func firstReadStart(windows: [HealthWindow], earliest: LocalDate?) throws(MetricsError) -> Int64 {
    let first = windows[0]
    guard let earliest, earliest < first.date else { return first.startMillis - Self.sampleLeadMillis }
    guard let limit = first.date.adding(days: -Self.firstReadLimitDays) else { return first.startMillis - Self.sampleLeadMillis }
    do throws(CalendarError) {
      return try HealthWindow(max(earliest, limit), in: clock).startMillis - Self.sampleLeadMillis
    } catch {
      throw .calendar(error)
    }
  }

  private static func write<Class: MetricClass>(
    _ dates: [LocalDate], of metric: MetricID<Class>, in transaction: inout WriteTransaction, value: (LocalDate) throws -> DecimalText?
  ) throws -> (changed: [LocalDate], unreadable: Int) {
    guard !dates.isEmpty else { return ([], 0) }
    try BuiltinMetric.seed(metric, in: &transaction)
    var changed = [LocalDate]()
    var unreadable = 0
    for date in dates {
      switch try MetricDays.setImported(try value(date), for: metric, on: date, in: &transaction) {
      case .written: changed.append(date)
      case .unchanged: break
      case .unreadable: unreadable += 1
      }
    }
    return (changed, unreadable)
  }
}

extension HealthImportReport {
  fileprivate mutating func add(_ outcome: (changed: [LocalDate], unreadable: Int), for metric: BuiltinMetric) {
    if !outcome.changed.isEmpty { changedDays[metric, default: []] += outcome.changed }
    unreadableDays += outcome.unreadable
  }
}

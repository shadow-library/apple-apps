import Foundation
import ShadowCore
import ShadowStore
import Synchronization

@testable import MemoirCore

/// A Health store as HealthKit presents it: totals per window, and per kind an ordered log of additions and deletions that anchors index into.
final class FakeHealthReader: HealthReader {
  private enum Event {
    case added(HealthSample)
    case deleted(UUID)
  }

  private struct State {
    var totals: [HealthTotal: [LocalDate: DecimalText]] = [:]
    var events: [HealthSampleKind: [Event]] = [:]
    var windows: [HealthTotal: [HealthWindow]] = [:]
    var failing: Set<HealthTotal> = []
    var firstReads: [HealthSampleKind: [Int64]] = [:]
  }

  private let state = Mutex(State())

  func setTotal(_ total: HealthTotal, _ value: DecimalText?, on date: LocalDate) {
    state.withLock { $0.totals[total, default: [:]][date] = value }
  }

  func add(_ kind: HealthSampleKind, _ samples: [HealthSample]) {
    state.withLock { $0.events[kind, default: []] += samples.map(Event.added) }
  }

  func delete(_ kind: HealthSampleKind, _ ids: [UUID]) {
    state.withLock { $0.events[kind, default: []] += ids.map(Event.deleted) }
  }

  func fail(_ total: HealthTotal) {
    state.withLock { _ = $0.failing.insert(total) }
  }

  func firstReadStarts(_ kind: HealthSampleKind) -> [Int64] {
    state.withLock { $0.firstReads[kind] ?? [] }
  }

  func requestedWindows(_ total: HealthTotal) -> [HealthWindow] {
    state.withLock { $0.windows[total] ?? [] }
  }

  func totals(of quantity: HealthTotal, in windows: [HealthWindow]) async throws(HealthReadError) -> [LocalDate: DecimalText] {
    let (values, failing) = state.withLock { state in
      state.windows[quantity] = windows
      return (state.totals[quantity] ?? [:], state.failing.contains(quantity))
    }
    if failing { throw .protectedDataUnavailable }
    return values.filter { date, _ in windows.contains { $0.date == date } }
  }

  func changes(of kind: HealthSampleKind, after anchor: HealthAnchor?, since startMillis: Int64) async throws(HealthReadError) -> HealthSampleChanges {
    let events = state.withLock { state in
      if anchor == nil { state.firstReads[kind, default: []].append(startMillis) }
      return state.events[kind] ?? []
    }
    let start = anchor.flatMap { Int(String(decoding: $0.data, as: UTF8.self)) } ?? 0
    var added = [HealthSample]()
    var deleted = [UUID]()
    for event in events[start...] {
      switch event {
      case .added(let sample): if anchor != nil || sample.startMillis >= startMillis { added.append(sample) }
      case .deleted(let id): deleted.append(id)
      }
    }
    return HealthSampleChanges(added: added, deleted: deleted, anchor: HealthAnchor(data: Data(String(events.count).utf8)))
  }
}

enum HealthFixture {
  static let today = date("2026-11-20")
  static let week = (0..<7).map { shifted(today, by: $0 - 6) }
  static let phone = HealthReaderDevice(id: MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000d001"), name: "Phone")
  static let tablet = HealthReaderDevice(id: MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000d002"), name: "Tablet")
  static let utc = IssueClock(timeZone: .gmt)
  static let minute: Int64 = 60_000
  static let hour: Int64 = 3_600_000

  static func date(_ text: String) -> LocalDate {
    guard let date = LocalDate(isoString: text) else { preconditionFailure("\(text) is a date") }
    return date
  }

  static func shifted(_ date: LocalDate, by days: Int) -> LocalDate {
    guard let shifted = date.adding(days: days) else { preconditionFailure("\(date) moved by \(days) days is a date") }
    return shifted
  }

  static func decimal(_ text: String) -> DecimalText {
    guard let value = DecimalText(text) else { preconditionFailure("\(text) is a canonical decimal") }
    return value
  }

  static func midnight(_ date: LocalDate) -> Int64 { Int64(date.daysSinceEpoch) * 86_400_000 }

  /// Noon UTC on `today`, as the wall clock the import reads.
  static func wallClock(_ date: LocalDate = today) -> @Sendable () -> Date {
    let instant = Date(timeIntervalSince1970: TimeInterval(midnight(date) + 12 * hour) / 1000)
    return { instant }
  }

  static func sampleID(_ kind: HealthSampleKind, _ index: Int) -> UUID {
    derivedID("com.shadow.library.memoircore.test-sample", "\(kind.rawValue)|\(index)")
  }

  /// Per day: steps 8,000 + 100·day; two weights, the later one 80.x1; a night of two overlapping asleep sources, 23:00–06:30 and 00:00–07:00.
  static func week(into reader: FakeHealthReader) {
    var weights = [HealthSample]()
    var sleep = [HealthSample]()
    for (index, day) in week.enumerated() {
      reader.setTotal(.stepCount, decimal(String(8_000 + 100 * index)), on: day)
      let morning = midnight(day) + 7 * hour
      weights.append(HealthSample(id: sampleID(.bodyMass, 2 * index), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: decimal("81.9")))
      weights.append(
        HealthSample(id: sampleID(.bodyMass, 2 * index + 1), startMillis: morning + hour, endMillis: morning + hour, utcOffsetMinutes: 0, quantity: decimal("80.\(index + 1)1")))
      sleep.append(HealthSample(id: sampleID(.sleep, 2 * index), startMillis: midnight(day) - hour, endMillis: midnight(day) + 6 * hour + 30 * minute, utcOffsetMinutes: 0))
      sleep.append(HealthSample(id: sampleID(.sleep, 2 * index + 1), startMillis: midnight(day), endMillis: midnight(day) + 7 * hour, utcOffsetMinutes: 0))
    }
    reader.add(.bodyMass, weights)
    reader.add(.sleep, sleep)
  }

  static func claim(_ device: HealthReaderDevice, in stores: MemoirStores, takingOver: Bool = false) async throws -> HealthReaderClaim {
    try await stores.main.write { transaction in try HealthSettings.claim(device, takingOver: takingOver, atMillis: 1, in: &transaction) }
  }

  static func values<Class: MetricClass>(_ metric: BuiltinMetric, _: Class.Type, in stores: MemoirStores) async throws -> [LocalDate: DecimalText] {
    try await stores.store(of: Class.syncClass).read { transaction in try MetricDays.values(of: MetricID<Class>(recordUUID: metric.id), in: transaction) }
  }

  static func day<Class: MetricClass>(_ metric: BuiltinMetric, _: Class.Type, on date: LocalDate, in stores: MemoirStores) async throws -> MetricDayRecord<Class>? {
    try await stores.store(of: Class.syncClass).read { transaction in
      try MetricDayRecord<Class>.read(key: .metricDay(Class.syncClass, metric: metric.id, date: date), in: transaction).entry?.record
    }
  }

  static func entityCount(_ kind: MemoirKind, in store: VaultStore) async throws -> Int {
    try await store.read { transaction in try transaction.states(ofKind: kind.entityKind).count }
  }

  static func anchors(in store: VaultStore) async throws -> [HealthSampleKind] {
    try await store.read { transaction in try HealthSampleKind.allCases.filter { try HealthSampleIndex.anchor(of: $0, in: transaction.database) != nil } }
  }

  static func exchangeAll(_ first: MemoirStores, _ second: MemoirStores) async throws {
    for kind in MemoirStoreKind.allCases { try await MemoirStoreFixture.exchange(first.store(kind), second.store(kind)) }
  }
}

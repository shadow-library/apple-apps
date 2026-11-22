import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

@MainActor
enum LogTesting {
  /// In the order they were issued.
  static func commands(in context: MemoirScreenContext) async throws -> [MemoirCommand] {
    let entries = try await context.stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries }
    return entries.sorted { $0.clock < $1.clock }.map(\.record)
  }

  static func bodies(in context: MemoirScreenContext) async throws -> [MemoirCommandBody] {
    try await commands(in: context).map { try MemoirCommandBody($0) }
  }

  static func count(_ kind: MemoirKind, in store: VaultStore) async throws -> Int {
    try await store.read { transaction in try transaction.states(ofKind: kind.entityKind).count }
  }

  /// The built-in metrics as the metrics read model describes them before any is seeded.
  static func builtinDescriptors() async throws -> [BuiltinMetric: MetricDescriptor] {
    let stores = try MemoirStores.openInMemory()
    let overview = try await LogReads.metrics(in: stores, classes: Set(SyncClass.allCases), activeQuests: [], today: TestClock.day0)
    var builtins = [BuiltinMetric: MetricDescriptor]()
    for series in overview.series { if let builtin = series.metric.builtin { builtins[builtin] = series.metric } }
    return builtins
  }

  static func suite() -> String {
    "com.shadow.apps.memoir.tests.\(UUID().uuidString)"
  }

  static func environment(
    _ availability: HealthAvailability = .available, device: HealthReaderDevice? = HealthReaderDevice(id: UUID(), name: "Phone"),
    source: FakeHealthSource = FakeHealthSource(), suite: String = suite()
  ) -> HealthEnvironment {
    HealthEnvironment(availability: availability, device: device, source: source, preferences: HealthPreferences(suiteName: suite))
  }
}

/// HealthKit as tests need it: every window's total is `total(of:)`, samples come from a queue per kind, and each call is recorded.
nonisolated final class FakeHealthSource: HealthSampleSource {
  private struct State {
    var totals: [HealthTotal: Double] = [:]
    var changes: [HealthSampleKind: [HealthRawChanges]] = [:]
    var failure: HealthReadError?
    var requested: [Set<HealthSource>] = []
    var windows: [(start: Date, end: Date)] = []
    var sampleCalls: [(kind: HealthSampleKind, anchor: Data?, since: Date)] = []
  }

  private let state = Mutex(State())

  init() {}

  func setTotal(_ value: Double?, of total: HealthTotal) {
    state.withLock { $0.totals[total] = value }
  }

  func enqueue(_ changes: HealthRawChanges, for kind: HealthSampleKind) {
    state.withLock { $0.changes[kind, default: []].append(changes) }
  }

  func fail(with error: HealthReadError?) {
    state.withLock { $0.failure = error }
  }

  var requested: [Set<HealthSource>] { state.withLock { $0.requested } }
  var windows: [(start: Date, end: Date)] { state.withLock { $0.windows } }
  var sampleCalls: [(kind: HealthSampleKind, anchor: Data?, since: Date)] { state.withLock { $0.sampleCalls } }

  func requestReading(_ sources: Set<HealthSource>) async throws(HealthReadError) {
    let failure = state.withLock { state -> HealthReadError? in
      state.requested.append(sources)
      return state.failure
    }
    if let failure { throw failure }
  }

  func sum(of total: HealthTotal, from start: Date, to end: Date) async throws(HealthReadError) -> Double? {
    let (value, failure) = state.withLock { state -> (Double?, HealthReadError?) in
      state.windows.append((start, end))
      return (state.totals[total], state.failure)
    }
    if let failure { throw failure }
    return value
  }

  func changes(of kind: HealthSampleKind, after anchor: Data?, since: Date) async throws(HealthReadError) -> HealthRawChanges {
    let (next, failure) = state.withLock { state -> (HealthRawChanges?, HealthReadError?) in
      state.sampleCalls.append((kind, anchor, since))
      guard var queue = state.changes[kind], !queue.isEmpty else { return (nil, state.failure) }
      let next = queue.removeFirst()
      state.changes[kind] = queue
      return (next, state.failure)
    }
    if let failure { throw failure }
    return next ?? HealthRawChanges(added: [], deleted: [], anchor: anchor ?? Data([1]))
  }
}

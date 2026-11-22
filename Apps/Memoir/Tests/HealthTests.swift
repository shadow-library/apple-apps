import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@Suite("HealthKitReader", TestTimeLimit.quick)
struct HealthKitReaderTests {
  private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

  @Test("should read each window's total once, leave out a window with nothing recorded and round to the metric's places")
  func readsTotals() async throws {
    let source = FakeHealthSource()
    source.setTotal(8123.6, of: .stepCount)
    let reader = HealthKitReader(source: source) { TestClock.utc }
    let windows = [
      HealthWindow(date: TestClock.day(0), startMillis: 0, endMillis: 86_400_000), HealthWindow(date: TestClock.day(1), startMillis: 86_400_000, endMillis: 172_800_000),
    ]

    let totals = try await reader.totals(of: .stepCount, in: windows)

    #expect(totals == [TestClock.day(0): try #require(DecimalText("8124")), TestClock.day(1): try #require(DecimalText("8124"))])
    #expect(source.windows.map(\.start) == [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 86_400)])
    source.setTotal(nil, of: .stepCount)
    #expect(try await reader.totals(of: .stepCount, in: windows).isEmpty)
  }

  @Test("should date a sample by the zone it was recorded in, else this device's, and keep quantities only for quantity kinds")
  func readsSamples() async throws {
    let source = FakeHealthSource()
    let recorded = HealthRawSample(id: UUID(), start: Date(timeIntervalSince1970: 3_600), end: Date(timeIntervalSince1970: 3_600), recordedZone: Self.tokyo, quantity: 72.456)
    let local = HealthRawSample(id: UUID(), start: Date(timeIntervalSince1970: 7_200), end: Date(timeIntervalSince1970: 7_200), recordedZone: nil, quantity: 71)
    let gone = UUID()
    source.enqueue(HealthRawChanges(added: [recorded, local], deleted: [gone], anchor: Data([7])), for: .bodyMass)
    let reader = HealthKitReader(source: source) { TestClock.berlin }

    let changes = try await reader.changes(of: .bodyMass, after: nil, since: 1_000)

    #expect(changes.added.map(\.utcOffsetMinutes) == [540, 60])
    #expect(changes.added.map(\.quantity) == [DecimalText("72.46"), DecimalText("71")])
    #expect(changes.added.map(\.startMillis) == [3_600_000, 7_200_000])
    #expect(changes.deleted == [gone] && changes.anchor == HealthAnchor(data: Data([7])))
    #expect(source.sampleCalls.first?.since == Date(timeIntervalSince1970: 1) && source.sampleCalls.first?.anchor == nil)

    let night = HealthRawSample(id: UUID(), start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 28_800), recordedZone: nil, quantity: 1)
    source.enqueue(HealthRawChanges(added: [night], deleted: [], anchor: Data([8])), for: .sleep)
    let sleep = try await reader.changes(of: .sleep, after: HealthAnchor(data: Data([7])), since: 0)
    #expect(sleep.added.first?.quantity == nil, "an interval carries no quantity")
    #expect(source.sampleCalls.last?.anchor == Data([7]))
  }

  @Test("should pass on HealthKit's failures, a locked device included")
  func passesOnFailures() async throws {
    let source = FakeHealthSource()
    source.fail(with: .protectedDataUnavailable)
    let reader = HealthKitReader(source: source)

    await #expect(throws: HealthReadError.protectedDataUnavailable) {
      try await reader.totals(of: .stepCount, in: [HealthWindow(date: TestClock.day0, startMillis: 0, endMillis: 1)])
    }
    await #expect(throws: HealthReadError.protectedDataUnavailable) { try await reader.changes(of: .workout, after: nil, since: 0) }
  }
}

@MainActor
@Suite("HealthReadingModel", TestTimeLimit.standard)
struct HealthReadingModelTests {
  private func reader(in stores: MemoirStores) async throws -> HealthReaderDesignation? {
    try await stores.main.read { transaction in try HealthSettings.designation(in: transaction) }
  }

  private func steps(in stores: MemoirStores) async throws -> [LocalDate: DecimalText] {
    try await stores.activity.read { transaction in try MetricDays.values(of: MetricID<ActivityMetric>(recordUUID: BuiltinMetric.steps.id), in: transaction) }
  }

  @Test("should make the first device to turn a metric on the reader, ask Health for that type, remember the choice and fill the week")
  func claimsAndImports() async throws {
    let context = try QuestsTesting.context()
    let source = FakeHealthSource()
    source.setTotal(9_000, of: .stepCount)
    let suite = LogTesting.suite()
    let environment = LogTesting.environment(source: source, suite: suite)
    let model = HealthReadingModel(environment: environment, stores: context.stores, clock: context.clock)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the designation loads") { model.designation.state != .loading }
      await model.set(.steps, reading: true)

      #expect(try await reader(in: context.stores)?.device == environment.device?.id)
      #expect(source.requested == [[.total(.stepCount)]])
      #expect(HealthPreferences(suiteName: suite).metrics == [.steps])
      #expect(try await steps(in: context.stores).count == HealthImport.defaultDays)
      #expect(try await steps(in: context.stores)[TestClock.day0] == DecimalText("9000"))
      try await TestClock.until("the model sees itself as the reader") { model.isThisDeviceReader }
      #expect(model.isReading(.steps) && !model.isReading(.water))
      #expect(try await LogTesting.bodies(in: context).isEmpty, "an import issues no command")
    }
  }

  @Test("should ask before a second device takes over, and stop the first at its next import")
  func asksBeforeTakingOver() async throws {
    let context = try QuestsTesting.context()
    let phone = LogTesting.environment(device: HealthReaderDevice(id: UUID(), name: "Phone"))
    let pad = LogTesting.environment(device: HealthReaderDevice(id: UUID(), name: "Pad"))
    let first = HealthReadingModel(environment: phone, stores: context.stores, clock: context.clock)
    let second = HealthReadingModel(environment: pad, stores: context.stores, clock: context.clock)
    await first.set(.water, reading: true)

    try await QuestsObservation { await second.observe() }.during {
      await second.set(.steps, reading: true)
      #expect(second.takeover == HealthReadingModel.Takeover(metric: .steps, current: try #require(try await reader(in: context.stores))))
      #expect(try await reader(in: context.stores)?.name == "Phone", "asking changes nothing")
      try await TestClock.until("the other reader shows") { second.otherReader?.name == "Phone" }
      second.cancelTakeover()
      await second.confirmTakeover()
      #expect(try await reader(in: context.stores)?.name == "Phone", "a cancelled question takes nothing over")

      await second.set(.steps, reading: true)
      await second.confirmTakeover()

      #expect(try await reader(in: context.stores)?.name == "Pad")
      try await TestClock.until("the pad reads") { second.isReading(.steps) }
    }
    let outcome = await HealthImportRunner(environment: phone, stores: context.stores, clock: context.clock).run()
    #expect(outcome == .notReader(try await reader(in: context.stores)))
    #expect(phone.preferences.metrics.isEmpty, "the device that lost the role forgets the metrics it read")
    #expect(await HealthImportRunner(environment: phone, stores: context.stores, clock: context.clock).run() == .skipped, "so it stops importing")
  }

  @Test("should forget the metrics it read once another device takes the role, and take it back with only the metric turned on then")
  func forgetsItsMetricsWhenTheRoleMoves() async throws {
    let context = try QuestsTesting.context()
    let phone = LogTesting.environment(device: HealthReaderDevice(id: UUID(), name: "Phone"))
    let pad = LogTesting.environment(device: HealthReaderDevice(id: UUID(), name: "Pad"))
    let first = HealthReadingModel(environment: phone, stores: context.stores, clock: context.clock)
    let second = HealthReadingModel(environment: pad, stores: context.stores, clock: context.clock)
    await first.set(.water, reading: true)
    await first.set(.sleep, reading: true)

    try await QuestsObservation { await first.observe() }.during {
      try await TestClock.until("the phone reads") { first.isReading(.water) }
      await second.set(.steps, reading: true)
      await second.confirmTakeover()
      try await TestClock.until("the phone sees the role move") { first.reading.isEmpty }
      #expect(phone.preferences.metrics.isEmpty)

      await first.set(.steps, reading: true)
      await first.confirmTakeover()

      try await TestClock.until("the phone reads again") { first.isReading(.steps) }
      #expect(phone.preferences.metrics == [.steps])
      #expect(!first.isReading(.water) && !first.isReading(.sleep))
    }
  }

  @Test("should give the designation up when the last metric is turned off here, keeping the imported days")
  func releasesWithTheLastMetric() async throws {
    let context = try QuestsTesting.context()
    let source = FakeHealthSource()
    source.setTotal(5_000, of: .stepCount)
    let model = HealthReadingModel(environment: LogTesting.environment(source: source), stores: context.stores, clock: context.clock)
    await model.set(.steps, reading: true)
    await model.set(.water, reading: true)

    await model.set(.water, reading: false)
    #expect(try await reader(in: context.stores) != nil)
    await model.set(.steps, reading: false)

    #expect(try await reader(in: context.stores) == nil)
    #expect(model.reading.isEmpty)
    #expect(try await steps(in: context.stores).isEmpty == false)
  }

  @Test("should read nothing and claim nothing on a Mac, in a build without HealthKit or on a device without Health data")
  func readsNothingWithoutHealth() async throws {
    for availability in [HealthAvailability.otherPlatform, .notEntitled, .unavailableOnDevice] {
      let context = try QuestsTesting.context()
      let source = FakeHealthSource()
      let environment = LogTesting.environment(availability, source: source)
      let model = HealthReadingModel(environment: environment, stores: context.stores, clock: context.clock)

      await model.set(.steps, reading: true)

      #expect(try await reader(in: context.stores) == nil)
      #expect(source.requested.isEmpty && !model.isReading(.steps))
      #expect(await HealthImportRunner(environment: environment, stores: context.stores, clock: context.clock).run([.steps]) == .skipped)
    }
  }

  @Test("should say there is no Health data yet for a metric read here that Health gave nothing for, as a refusal looks")
  func showsNoDataForARefusal() async throws {
    let context = try QuestsTesting.context()
    let model = HealthReadingModel(environment: LogTesting.environment(), stores: context.stores, clock: context.clock)

    try await QuestsObservation { await model.observe() }.during {
      await model.set(.steps, reading: true)
      try await TestClock.until("the model sees itself as the reader") { model.isThisDeviceReader }
      let overview = try await LogReads.metrics(in: context.stores, classes: [.activity], activeQuests: [], today: TestClock.day0)
      let steps = overview.series.first { $0.metric.builtin == .steps }
      #expect(model.showsNoData(.steps, in: steps))
      #expect(!model.showsNoData(.water, in: nil), "a metric not read from Health is only typed")
    }
  }
}

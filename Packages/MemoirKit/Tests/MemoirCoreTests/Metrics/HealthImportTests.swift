import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("HealthImport", TestTimeLimit.standard)
struct HealthImportTests {
  private func importer(_ reader: FakeHealthReader, _ stores: MemoirStores, device: HealthReaderDevice = HealthFixture.phone, clock: IssueClock = HealthFixture.utc)
    -> HealthImport
  {
    HealthImport(reader: reader, stores: stores, device: device, clock: clock, wallClock: HealthFixture.wallClock())
  }

  private func pendingCount(_ stores: MemoirStores) async throws -> [Int] {
    var counts = [Int]()
    for kind in MemoirStoreKind.allCases { counts.append(try await stores.store(kind).pendingChanges(limit: .max).count) }
    return counts
  }

  @Test func shouldFillAWeekOfStepsWeightAndSleepIdempotently() async throws {
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)

    let report = try await importer(reader, stores).run([.steps, .weight, .sleep])

    #expect(report.changedDays[.steps] == HealthFixture.week)
    #expect(report.changedDays[.weight] == HealthFixture.week)
    #expect(report.changedDays[.sleep] == HealthFixture.week)
    let steps = try await HealthFixture.values(.steps, ActivityMetric.self, in: stores)
    let weight = try await HealthFixture.values(.weight, HealthMetric.self, in: stores)
    let sleep = try await HealthFixture.values(.sleep, HealthMetric.self, in: stores)
    for (index, day) in HealthFixture.week.enumerated() {
      #expect(steps[day] == HealthFixture.decimal(String(8_000 + 100 * index)))
      #expect(weight[day] == HealthFixture.decimal("80.\(index + 1)1"))
      #expect(sleep[day] == HealthFixture.decimal("480"))
    }
    #expect(try await HealthFixture.entityCount(.activityMetric, in: stores.activity) == 1)
    #expect(try await HealthFixture.entityCount(.healthMetric, in: stores.restricted) == 2)

    let pending = try await pendingCount(stores)
    let again = try await importer(reader, stores).run([.steps, .weight, .sleep])
    #expect(again.changedDays.isEmpty)
    #expect(try await pendingCount(stores) == pending)
    #expect(try await HealthFixture.entityCount(.activityMetricDay, in: stores.activity) == 7)
    #expect(try await HealthFixture.entityCount(.healthMetricDay, in: stores.restricted) == 14)
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 0)
  }

  @Test func shouldConvergeTwoReadersOnOneRecordPerMetricAndDay() async throws {
    let phone = try MemoirStores.openInMemory()
    let tablet = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: phone)
    _ = try await HealthFixture.claim(HealthFixture.tablet, in: tablet)
    _ = try await importer(reader, phone).run([.steps, .weight, .sleep])
    _ = try await importer(reader, tablet, device: HealthFixture.tablet).run([.steps, .weight, .sleep])

    try await HealthFixture.exchangeAll(phone, tablet)

    for stores in [phone, tablet] {
      #expect(try await HealthFixture.entityCount(.activityMetricDay, in: stores.activity) == 7)
      #expect(try await HealthFixture.entityCount(.healthMetricDay, in: stores.restricted) == 14)
      #expect(try await HealthFixture.entityCount(.healthMetric, in: stores.restricted) == 2)
    }
    #expect(try await phone.restricted.loadState(.vault).digest == tablet.restricted.loadState(.vault).digest)
    #expect(try await phone.activity.loadState(.vault).digest == tablet.activity.loadState(.vault).digest)
    let designations = [
      try await phone.main.read { transaction in try HealthSettings.designation(in: transaction) },
      try await tablet.main.read { transaction in try HealthSettings.designation(in: transaction) },
    ]
    #expect(designations[0] == designations[1])
    let loser = designations[0]?.device == HealthFixture.phone.id ? (tablet, HealthFixture.tablet) : (phone, HealthFixture.phone)
    #expect(try await HealthFixture.anchors(in: loser.0.restricted) == [.bodyMass, .sleep])
    await #expect(throws: MetricsError.self) { try await importer(reader, loser.0, device: loser.1).run([.weight]) }
    #expect(try await HealthFixture.anchors(in: loser.0.restricted).isEmpty)
  }

  @Test func shouldKeepTheOwnersEntryOverAnImportWrittenElsewhereAtTheSameTime() async throws {
    let mac = try MemoirStores.openInMemory()
    let phone = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: phone)
    let day = HealthFixture.today
    let catalog = MetricCatalog(stores: mac, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    try await catalog.register(HealthFixture.decimal("79.5"), for: BuiltinMetric.weight.reference, on: day)
    _ = try await importer(reader, phone).run([.weight])

    try await HealthFixture.exchangeAll(mac, phone)

    for stores in [mac, phone] {
      let record = try #require(try await HealthFixture.day(.weight, HealthMetric.self, on: day, in: stores))
      #expect(record.value == HealthFixture.decimal("79.5"))
      #expect(record.entry?.source == .known(.manual))
      #expect(record.imported == HealthFixture.decimal("80.71"))
    }
    let evening = HealthFixture.midnight(day) + 20 * HealthFixture.hour
    reader.add(.bodyMass, [HealthSample(id: UUID(), startMillis: evening, endMillis: evening, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("80.7"))])
    _ = try await importer(reader, phone).run([.weight])
    #expect(try await HealthFixture.day(.weight, HealthMetric.self, on: day, in: phone)?.value == HealthFixture.decimal("79.5"))

    try await MetricCatalog(stores: phone, issuer: catalog.issuer).clearEntry(for: BuiltinMetric.weight.reference, on: day)
    #expect(try await HealthFixture.day(.weight, HealthMetric.self, on: day, in: phone)?.value == HealthFixture.decimal("80.7"))
    let commands = try await mac.main.read { transaction in try MemoirCommand.listing(in: transaction) }
    #expect(commands.entries.isEmpty)
  }

  @Test func shouldClearOrMoveADayWhenHealthDeletesOrEditsItsSamples() async throws {
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)
    _ = try await importer(reader, stores).run([.weight, .sleep])
    let monday = HealthFixture.week[0]
    let tuesday = HealthFixture.week[1]

    reader.delete(.bodyMass, [HealthFixture.sampleID(.bodyMass, 1)])
    reader.delete(.bodyMass, [HealthFixture.sampleID(.bodyMass, 2), HealthFixture.sampleID(.bodyMass, 3)])
    reader.delete(.sleep, [HealthFixture.sampleID(.sleep, 1)])
    let report = try await importer(reader, stores).run([.weight, .sleep])

    #expect(report.changedDays[.weight] == [monday, tuesday])
    #expect(try await HealthFixture.day(.weight, HealthMetric.self, on: monday, in: stores)?.value == HealthFixture.decimal("81.9"))
    let cleared = try #require(try await HealthFixture.day(.weight, HealthMetric.self, on: tuesday, in: stores))
    #expect(cleared.imported == nil && cleared.value == nil)
    #expect(try await HealthFixture.values(.weight, HealthMetric.self, in: stores)[tuesday] == nil)
    #expect(try await HealthFixture.day(.sleep, HealthMetric.self, on: monday, in: stores)?.value == HealthFixture.decimal("450"))

    reader.delete(.bodyMass, [HealthFixture.sampleID(.bodyMass, 0)])
    let start = HealthFixture.midnight(tuesday) + 9 * HealthFixture.hour
    reader.add(.bodyMass, [HealthSample(id: UUID(), startMillis: start, endMillis: start, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("81.2"))])
    _ = try await importer(reader, stores).run([.weight])
    #expect(try await HealthFixture.day(.weight, HealthMetric.self, on: monday, in: stores)?.imported == nil)
    #expect(try await HealthFixture.day(.weight, HealthMetric.self, on: tuesday, in: stores)?.imported == HealthFixture.decimal("81.2"))
  }

  @Test func shouldReadTotalsOverTheAccountZonesDaysAndDateSamplesByTheirRecordedOffset() async throws {
    let berlin = IssueClock(timeZone: try #require(TimeZone(identifier: "Europe/Berlin")))
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    let today = HealthFixture.date("2026-03-30")
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)
    let late = HealthFixture.midnight(today) - 30 * HealthFixture.minute
    let tokyo = HealthFixture.midnight(today) - 10 * HealthFixture.hour
    reader.add(
      .bodyMass,
      [
        HealthSample(id: HealthFixture.sampleID(.bodyMass, 0), startMillis: late, endMillis: late, utcOffsetMinutes: 120, quantity: HealthFixture.decimal("70")),
        HealthSample(id: HealthFixture.sampleID(.bodyMass, 1), startMillis: tokyo, endMillis: tokyo, utcOffsetMinutes: 540, quantity: HealthFixture.decimal("71")),
      ])
    let run = HealthImport(reader: reader, stores: stores, device: HealthFixture.phone, clock: berlin, wallClock: HealthFixture.wallClock(today))

    let report = try await run.run([.steps, .weight], days: 3)

    let windows = reader.requestedWindows(.stepCount)
    #expect(windows.map(\.date) == [HealthFixture.date("2026-03-28"), HealthFixture.date("2026-03-29"), today])
    #expect(windows.map { ($0.endMillis - $0.startMillis) / HealthFixture.hour } == [24, 23, 24])
    #expect(windows[1].startMillis == HealthFixture.midnight(HealthFixture.date("2026-03-29")) - HealthFixture.hour)
    #expect(report.changedDays[.weight] == [HealthFixture.date("2026-03-29"), today])
    let weight = try await HealthFixture.values(.weight, HealthMetric.self, in: stores)
    #expect(weight[today] == HealthFixture.decimal("70"))
    #expect(weight[HealthFixture.date("2026-03-29")] == HealthFixture.decimal("71"))
  }

  @Test func shouldDateANightByTheMorningItEndsOn() {
    let day = HealthFixture.date("2026-11-20")
    let evening = HealthFixture.midnight(day) - 4 * HealthFixture.hour
    let early = HealthSample(id: UUID(), startMillis: evening - HealthFixture.hour, endMillis: evening, utcOffsetMinutes: 0)
    let afternoon = HealthSample(id: UUID(), startMillis: evening - 5 * HealthFixture.hour, endMillis: evening - 6 * HealthFixture.hour - 1, utcOffsetMinutes: 0)
    let nap = HealthSample(id: UUID(), startMillis: evening - 8 * HealthFixture.hour, endMillis: evening - 7 * HealthFixture.hour, utcOffsetMinutes: 0)
    #expect(HealthSampleIndex.day(of: early, kind: .sleep) == day)
    #expect(HealthSampleIndex.day(of: nap, kind: .sleep) == day.adding(days: -1))
    #expect(HealthSampleIndex.day(of: afternoon, kind: .sleep) == nil)
    #expect(HealthSampleIndex.day(of: HealthSample(id: UUID(), startMillis: 0, endMillis: 0, utcOffsetMinutes: 0), kind: .bodyMass) == nil)
    #expect(
      HealthSampleIndex.day(of: HealthSample(id: UUID(), startMillis: 0, endMillis: 0, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("-1")), kind: .bodyMass) == nil)
  }

  @Test func shouldReportAFailedReadAndKeepImportingTheOtherMetrics() async throws {
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    reader.fail(.stepCount)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)

    let report = try await importer(reader, stores).run([.steps, .weight])

    #expect(report.failed == [.steps: .protectedDataUnavailable])
    #expect(report.changedDays[.weight]?.count == 7)
    #expect(try await HealthFixture.entityCount(.activityMetricDay, in: stores.activity) == 0)
  }

  @Test func shouldNotReadOnADeviceThatIsNotTheDesignatedReader() async throws {
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    await #expect(throws: MetricsError.self) { try await importer(reader, stores).run() }
    #expect(try await HealthFixture.claim(HealthFixture.phone, in: stores) == .claimed(previous: nil))
    #expect(try await HealthFixture.claim(HealthFixture.phone, in: stores) == .alreadyReader)
    _ = try await importer(reader, stores).run([.weight])

    let held = try await HealthFixture.claim(HealthFixture.tablet, in: stores)
    guard case .heldByAnother(let designation) = held else { throw MemoirFixtureError(description: "expected the claim to ask first, got \(held)") }
    #expect(designation.device == HealthFixture.phone.id && designation.name == "Phone")
    #expect(try await HealthFixture.claim(HealthFixture.tablet, in: stores, takingOver: true) == .claimed(previous: designation))

    do {
      _ = try await importer(reader, stores).run([.weight])
      Issue.record("the former reader imported")
    } catch {
      guard case .notReader(let current?) = error else { throw MemoirFixtureError(description: "unexpected \(error)") }
      #expect(current.device == HealthFixture.tablet.id)
    }
    #expect(try await HealthFixture.anchors(in: stores.restricted).isEmpty)
    #expect(try await HealthFixture.values(.weight, HealthMetric.self, in: stores).count == 7)
  }
}

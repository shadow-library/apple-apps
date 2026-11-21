import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Metric day merges", TestTimeLimit.standard)
struct MetricDayMergeTests {
  private static let metric = MetricID<HealthMetric>(recordUUID: MemoirStoreFixture.metric)
  private static let day = HealthFixture.today
  private static let key = MemoirKey.metricDay(.health, metric: MemoirStoreFixture.metric, date: HealthFixture.today)

  private enum Order: CaseIterable {
    case firstToSecondFirst
    case secondToFirstFirst
  }

  private func deliver(_ first: VaultStore, _ second: VaultStore, _ order: Order) async throws {
    let fromFirst = try await first.pendingChanges(limit: .max).map(\.line)
    let fromSecond = try await second.pendingChanges(limit: .max).map(\.line)
    switch order {
    case .firstToSecondFirst:
      _ = try await second.applyRemote(fromFirst)
      _ = try await first.applyRemote(fromSecond)
    case .secondToFirstFirst:
      _ = try await first.applyRemote(fromSecond)
      _ = try await second.applyRemote(fromFirst)
    }
  }

  private func enter(_ entry: MetricEntry?, in store: VaultStore) async throws {
    _ = try await store.write { transaction in try MetricDays.enter(entry, for: Self.metric, on: Self.day, in: &transaction) }
  }

  private func reading(_ store: VaultStore) async throws -> MemoirReading<MemoirEntry<MetricDayRecord<HealthMetric>>> {
    try await store.read { transaction in try MetricDayRecord<HealthMetric>.read(key: Self.key, in: transaction) }
  }

  @Test func shouldNeverTearTheOwnersEntryWhenTwoDevicesWriteItAtOnce() async throws {
    let manual = MetricEntry(value: HealthFixture.decimal("5"), source: .known(.manual))
    let food = MetricEntry(value: HealthFixture.decimal("7"), source: .known(.food))
    for order in Order.allCases {
      let first = try MemoirStore.openInMemory(.restricted)
      let second = try MemoirStore.openInMemory(.restricted)
      try await enter(manual, in: first)
      try await enter(food, in: second)

      try await deliver(first, second, order)

      let readings = [try await reading(first), try await reading(second)]
      #expect(readings[0] == readings[1])
      let entry = try #require(readings[0].entry?.record.entry)
      #expect(entry == manual || entry == food)
    }
  }

  @Test func shouldEndWithAWholeEntryOrNoneWhenOneDeviceClearsItAsAnotherChangesIt() async throws {
    let before = MetricEntry(value: HealthFixture.decimal("5"))
    let after = MetricEntry(value: HealthFixture.decimal("6"))
    for order in Order.allCases {
      let first = try MemoirStore.openInMemory(.restricted)
      let second = try MemoirStore.openInMemory(.restricted)
      try await enter(before, in: first)
      try await MemoirStoreFixture.exchange(first, second)
      try await enter(after, in: first)
      try await enter(nil, in: second)

      try await deliver(first, second, order)

      let readings = [try await reading(first), try await reading(second)]
      #expect(readings[0] == readings[1])
      let record = try #require(readings[0].entry?.record)
      #expect(record.entry == nil || record.entry == after)
    }
  }

  @Test func shouldNeverTearAQuestThresholdWhenTwoDevicesSetItAtOnce() async throws {
    let other = MetricID<HealthMetric>(recordUUID: UUID())
    let thresholds = [
      QuestThresholdRecord(quest: MemoirStoreFixture.quest, metric: Self.metric, value: HealthFixture.decimal("8000"), comparison: .known(.atLeast)),
      QuestThresholdRecord(quest: MemoirStoreFixture.quest, metric: other, value: HealthFixture.decimal("2000"), comparison: .known(.atMost)),
    ]
    for order in Order.allCases {
      let first = try MemoirStore.openInMemory(.restricted)
      let second = try MemoirStore.openInMemory(.restricted)
      _ = try await first.write { transaction in try thresholds[0].create(in: &transaction) }
      _ = try await second.write { transaction in try thresholds[1].create(in: &transaction) }

      try await deliver(first, second, order)

      let readings = [
        try await first.read { transaction in try QuestThresholdRecord<HealthMetric>.read(id: MemoirStoreFixture.quest, in: transaction) },
        try await second.read { transaction in try QuestThresholdRecord<HealthMetric>.read(id: MemoirStoreFixture.quest, in: transaction) },
      ]
      #expect(readings[0] == readings[1])
      let record = try #require(readings[0].entry?.record)
      #expect(thresholds.contains(record))
    }
  }

  @Test func shouldKeepADayRemovedElsewhereWhenAnImportCreatesItBeforeTheRemovalArrives() async throws {
    let first = try MemoirStore.openInMemory(.restricted)
    let second = try MemoirStore.openInMemory(.restricted)
    _ = try await first.write { transaction in try MetricDays.setImported(HealthFixture.decimal("58"), for: Self.metric, on: Self.day, in: &transaction) }
    _ = try await first.write { transaction in try MetricDayRecord<HealthMetric>.remove(Self.key.ref, in: &transaction) }
    _ = try await second.write { transaction in try MetricDays.setImported(HealthFixture.decimal("59"), for: Self.metric, on: Self.day, in: &transaction) }

    try await MemoirStoreFixture.exchange(first, second)

    for store in [first, second] {
      #expect(try await reading(store).entry?.isRemoved == true)
      #expect(try await store.read { transaction in try MetricDays.values(of: Self.metric, in: transaction) }.isEmpty)
    }
    try await enter(MetricEntry(value: HealthFixture.decimal("60")), in: second)
    #expect(try await reading(second).entry?.isRemoved == false)
  }
}

@Suite("HealthImport after a takeover", TestTimeLimit.standard)
struct HealthTakeoverTests {
  @Test func shouldKeepThePreviousReadersValuesOnTheFirstReadAndSeeLaterDeletionsOfOlderSamples() async throws {
    let phone = try MemoirStores.openInMemory()
    let tablet = try MemoirStores.openInMemory()
    let phoneHealth = FakeHealthReader()
    let tabletHealth = FakeHealthReader()
    let month = (0..<30).map { HealthFixture.shifted(HealthFixture.today, by: $0 - 29) }
    for (index, day) in month.enumerated() {
      phoneHealth.setTotal(.stepCount, HealthFixture.decimal(String(5_000 + index)), on: day)
      let morning = HealthFixture.midnight(day) + 7 * HealthFixture.hour
      let sample = HealthSample(
        id: HealthFixture.sampleID(.bodyMass, index), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("70.\(index + 1)1"))
      phoneHealth.add(.bodyMass, [sample])
      tabletHealth.add(.bodyMass, [sample])
      if index % 2 == 0 { tabletHealth.setTotal(.stepCount, HealthFixture.decimal(String(5_000 + index)), on: day) }
    }
    _ = try await HealthFixture.claim(HealthFixture.phone, in: phone)
    _ = try await HealthImport(reader: phoneHealth, stores: phone, device: HealthFixture.phone, clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
      .run([.steps, .weight], days: 30)
    try await HealthFixture.exchangeAll(phone, tablet)
    _ = try await HealthFixture.claim(HealthFixture.tablet, in: tablet, takingOver: true)
    let importer = HealthImport(reader: tabletHealth, stores: tablet, device: HealthFixture.tablet, clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())

    _ = try await importer.run([.steps, .weight])

    #expect(try await HealthFixture.values(.steps, ActivityMetric.self, in: tablet).count == 30)
    #expect(tabletHealth.firstReadStarts(.bodyMass) == [HealthFixture.midnight(month[0]) - HealthImport.sampleLeadMillis])
    tabletHealth.delete(.bodyMass, [HealthFixture.sampleID(.bodyMass, 3)])
    _ = try await importer.run([.steps, .weight])
    let weight = try await HealthFixture.values(.weight, HealthMetric.self, in: tablet)
    #expect(weight[month[3]] == nil)
    #expect(weight.count == 29)
    let steps = try await HealthFixture.values(.steps, ActivityMetric.self, in: tablet)
    #expect(steps.count == 26)
    #expect(steps[HealthFixture.today] == nil)
    #expect(steps[month[28]] == HealthFixture.decimal("5028"))
    #expect(steps[month[21]] == HealthFixture.decimal("5021"))
  }
}

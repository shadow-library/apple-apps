import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

/// The cases of the reference's `tests/metrics/threshold-offer.spec.ts`, over the native inputs.
@Suite("ThresholdOffers", TestTimeLimit.quick)
struct ThresholdOfferTests {
  private static let steps = MetricReference(id: MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000e1"), metricClass: .activity)
  private static let sleep = MetricReference(id: MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000e2"), metricClass: .health)
  private static let walk = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000f0")
  private static let rest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000f1")
  private static let read = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000f2")
  private static let sitLess = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000f3")
  private static let quests: [(id: UUID, name: String)] = [(walk, "Walk"), (rest, "Rest"), (read, "Read"), (sitLess, "Sit less")]
  private static let thresholds = [
    QuestThreshold(quest: walk, metric: steps, value: HealthFixture.decimal("8000"), comparison: .atLeast),
    QuestThreshold(quest: rest, metric: sleep, value: HealthFixture.decimal("7"), comparison: .atLeast),
    QuestThreshold(quest: sitLess, metric: steps, value: HealthFixture.decimal("2000"), comparison: .atMost),
  ]
  private static let start = HealthFixture.date("2026-01-01")

  private func days() -> (days: [MetricDayValue], logged: Set<Occurrence>) {
    var days = [MetricDayValue]()
    var logged = Set<Occurrence>()
    for day in 0..<30 {
      let date = Self.start.adding(days: day)!
      days.append(MetricDayValue(metric: Self.steps, date: date, value: HealthFixture.decimal(String((day * 997) % 12_000))))
      if day % 3 == 0 { logged.insert(Occurrence(quest: Self.walk, date: date)) }
      if day % 4 == 0 { logged.insert(Occurrence(quest: Self.rest, date: date)) }
    }
    for day in 0..<30 {
      days.append(MetricDayValue(metric: Self.sleep, date: Self.start.adding(days: day)!, value: HealthFixture.decimal(String(4 + day % 6))))
    }
    return (days, logged)
  }

  @Test func shouldOfferEveryCrossedThresholdWithoutALoggedOccurrenceInTheReferencesOrder() {
    let (days, logged) = days()
    let offers = ThresholdOffers.offers(thresholds: Self.thresholds, days: days, activeQuests: Self.quests, logged: logged)

    var expected = [ThresholdOffer]()
    for day in days {
      for quest in Self.quests {
        guard let threshold = Self.thresholds.first(where: { $0.quest == quest.id }), threshold.metric == day.metric else { continue }
        let value = Int(day.value.text)!
        let limit = Int(threshold.value.text)!
        guard threshold.comparison == .atLeast ? value >= limit : value <= limit, !logged.contains(Occurrence(quest: quest.id, date: day.date)) else { continue }
        expected.append(
          ThresholdOffer(
            quest: quest.id, questName: quest.name, metric: day.metric, date: day.date, thresholdValue: threshold.value, currentValue: day.value,
            comparison: threshold.comparison))
      }
    }
    #expect(offers == expected)
    #expect(!offers.isEmpty)
    #expect(Set(offers.map(\.quest)) == [Self.walk, Self.rest, Self.sitLess])
  }

  @Test func shouldOfferNothingWithoutAThresholdOrADay() {
    let (days, logged) = days()
    #expect(ThresholdOffers.offers(thresholds: [], days: days, activeQuests: Self.quests, logged: logged).isEmpty)
    #expect(ThresholdOffers.offers(thresholds: Self.thresholds, days: [], activeQuests: Self.quests, logged: logged).isEmpty)
  }

  @Test func shouldOfferEveryCrossedQuestForOneDayExceptOneAlreadyLogged() {
    let date = HealthFixture.date("2026-03-01")
    let day = MetricDayValue(metric: Self.steps, date: date, value: HealthFixture.decimal("1500"))
    let offers = ThresholdOffers.offers(thresholds: Self.thresholds, days: [day], activeQuests: Self.quests, logged: [Occurrence(quest: Self.walk, date: date)])
    #expect(offers.map(\.quest) == [Self.sitLess])
    let quiet = MetricDayValue(metric: Self.steps, date: date, value: HealthFixture.decimal("5000"))
    #expect(ThresholdOffers.offers(thresholds: Self.thresholds, days: [quiet], activeQuests: Self.quests, logged: []).isEmpty)
  }

  @Test func shouldNeverOfferForAGeneralMetric() async throws {
    let pages = MetricReference(id: UUID(), metricClass: .general)
    let threshold = QuestThreshold(quest: Self.read, metric: pages, value: HealthFixture.decimal("10"), comparison: .atLeast)
    let day = MetricDayValue(metric: pages, date: Self.start, value: HealthFixture.decimal("30"))
    #expect(ThresholdOffers.offers(thresholds: [threshold], days: [day], activeQuests: Self.quests, logged: []).isEmpty)

    let stores = try MemoirStores.openInMemory()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let stored = try await catalog.create(MetricDefinition(name: "Pages read", valueType: .count, direction: .higher), as: .general)
    try await catalog.register(HealthFixture.decimal("30"), for: stored, on: HealthFixture.today)
    _ = try await stores.main.write { transaction in try QuestRecord(id: Self.read, name: "Read").create(in: &transaction) }
    try await QuestThresholds.set(QuestThreshold(quest: Self.read, metric: stored, value: HealthFixture.decimal("10"), comparison: .atLeast), in: stores)
    #expect(try await HealthFixture.entityCount(.generalQuestThreshold, in: stores.main) == 1)
    #expect(try await ThresholdOffers.current(in: stores, activeQuests: [Self.read], logged: []).isEmpty)
  }

  @Test func shouldCompareDecimalsExactlyAtTheThreshold() {
    let at = QuestThreshold(quest: Self.walk, metric: Self.steps, value: HealthFixture.decimal("7.5"), comparison: .atLeast)
    let most = QuestThreshold(quest: Self.walk, metric: Self.steps, value: HealthFixture.decimal("-0.25"), comparison: .atMost)
    #expect(at.isCrossed(by: HealthFixture.decimal("7.5")))
    #expect(at.isCrossed(by: HealthFixture.decimal("10")))
    #expect(!at.isCrossed(by: HealthFixture.decimal("7.49")))
    #expect(most.isCrossed(by: HealthFixture.decimal("-0.25")) && most.isCrossed(by: HealthFixture.decimal("-1")))
    #expect(!most.isCrossed(by: HealthFixture.decimal("-0.2")) && !most.isCrossed(by: HealthFixture.decimal("0")))
    let sorted = ["-12.5", "-3", "-0.25", "0", "0.05", "0.5", "1", "9.99", "10", "123.4"].map(HealthFixture.decimal)
    #expect(sorted.shuffled().sorted() == sorted)
  }

  @Test func shouldReadOffersFromTheStoresOfEachClassAndWriteNothing() async throws {
    let stores = try MemoirStores.openInMemory()
    let reader = FakeHealthReader()
    HealthFixture.week(into: reader)
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)
    _ = try await HealthImport(reader: reader, stores: stores, device: HealthFixture.phone, clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
      .run([.steps, .sleep])
    _ = try await stores.main.write { transaction in
      try QuestRecord(id: Self.walk, name: "Walk").create(in: &transaction)
      try QuestRecord(id: Self.rest, name: "Rest").create(in: &transaction)
    }
    try await QuestThresholds.set(
      QuestThreshold(quest: Self.walk, metric: BuiltinMetric.steps.reference, value: HealthFixture.decimal("8500"), comparison: .atLeast), in: stores)
    try await QuestThresholds.set(
      QuestThreshold(quest: Self.rest, metric: BuiltinMetric.sleep.reference, value: HealthFixture.decimal("480"), comparison: .atLeast), in: stores)
    let pending = try await [stores.main, stores.activity, stores.restricted].asyncMap { try await $0.pendingChanges(limit: .max).count }
    let today = HealthFixture.today
    let logged: Set<Occurrence> = [Occurrence(quest: Self.walk, date: today)]

    let offers = try await ThresholdOffers.current(in: stores, activeQuests: [Self.walk, Self.rest], logged: logged)

    let walkDates = offers.filter { $0.quest == Self.walk }.map(\.date)
    #expect(walkDates == Array(HealthFixture.week[5...5]))
    #expect(offers.filter { $0.quest == Self.rest }.map(\.date) == HealthFixture.week)
    #expect(offers.first { $0.quest == Self.walk }?.currentValue == HealthFixture.decimal("8500"))
    #expect(try await [stores.main, stores.activity, stores.restricted].asyncMap { try await $0.pendingChanges(limit: .max).count } == pending)
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 0)

    try await QuestThresholds.set(
      QuestThreshold(quest: Self.walk, metric: BuiltinMetric.workoutMinutes.reference, value: HealthFixture.decimal("30"), comparison: .atLeast), in: stores)
    let moved = try await ThresholdOffers.current(in: stores, activeQuests: [Self.walk, Self.rest], logged: logged)
    #expect(moved.allSatisfy { $0.quest == Self.rest })
    #expect(try await ThresholdOffers.current(in: stores, activeQuests: [Self.walk], logged: logged).isEmpty)
    try await QuestThresholds.clear(quest: Self.rest, in: stores)
    #expect(try await ThresholdOffers.current(in: stores, activeQuests: [Self.walk, Self.rest], logged: logged).isEmpty)
  }
}

extension Array {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var values = [T]()
    for element in self { values.append(try await transform(element)) }
    return values
  }
}

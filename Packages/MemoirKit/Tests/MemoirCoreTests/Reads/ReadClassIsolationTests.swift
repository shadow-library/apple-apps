import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir quest and hero reads class isolation", TestTimeLimit.quick)
struct ReadClassIsolationTests {
  private static let healthValues = ["81.2345", "53.0917", "Glucosamine Xq", "6.4321"]
  private static let activityValues = ["98765", "4321.77"]
  private static let quest = MemoirStoreFixture.quest

  /// The vault filled as `ClassIsolationTests` fills it, with the quest it names created and a health threshold on it, then every read model loaded:
  /// the general quest's name reaches them and no health or activity value does.
  @Test func shouldKeepEveryHealthAndActivityValueOutOfTheReadModels() async throws {
    nonisolated(unsafe) var opened: MemoirStores?
    let device = try ReadsDevice { reconciler in
      let stores = try MemoirStores.openInMemory(wallClock: HealthFixture.wallClock(), projection: reconciler)
      opened = stores
      return stores.main
    }
    let stores = try #require(opened)
    let today = HealthFixture.today
    try await device.create(Self.quest, nil, schedule: try ReadsDevice.schedule(.routine, start: 480, recurrence: try ReadsDevice.daily(from: today)), on: today)

    let reader = FakeHealthReader()
    let morning = HealthFixture.midnight(today) + 7 * HealthFixture.hour
    reader.setTotal(.stepCount, HealthFixture.decimal("98765"), on: today)
    reader.add(.bodyMass, [HealthSample(id: UUID(), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("81.2345"))])
    reader.add(.restingHeartRate, [HealthSample(id: UUID(), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("53.0917"))])
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)
    _ = try await HealthImport(reader: reader, stores: stores, device: HealthFixture.phone, clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()).run()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let glucose = try await catalog.create(MetricDefinition(name: "Glucosamine Xq", unit: "mmol/L", valueType: .number, direction: .range))
    try await catalog.register(HealthFixture.decimal("6.4321"), for: glucose, on: today)
    try await catalog.register(HealthFixture.decimal("4321.77"), for: BuiltinMetric.steps.reference, on: HealthFixture.shifted(today, by: -1))
    try await QuestThresholds.set(QuestThreshold(quest: Self.quest, metric: glucose, value: HealthFixture.decimal("6.4321"), comparison: .atMost), in: stores)
    _ = try await QuickLogWriter(stores: stores, issuer: catalog.issuer).saveWeight(HealthFixture.decimal("81.2345"), on: HealthFixture.shifted(today, by: -2))
    _ = try await stores.main.write { transaction in try QuestRecord(id: Self.quest, name: "Marker Quest Zq").create(in: &transaction) }
    try await device.walk(to: HealthFixture.shifted(today, by: 1))

    let tomorrow = HealthFixture.shifted(today, by: 1)
    let dumps: [String] = [
      String(reflecting: try await device.board(today)), String(reflecting: try await device.board(tomorrow)),
      String(reflecting: try await device.load(QuestList.self, QuestListQuery(filter: .all))),
      String(reflecting: try await device.load(QuestDetail.self, QuestDetailQuery(quest: Self.quest))),
      String(reflecting: try await device.load(StreakBoard.self, StreakBoardQuery(date: tomorrow))),
      String(reflecting: try await device.load(PlanBoard.self, PlanBoardQuery(scope: .month(containing: today)))),
      String(
        reflecting: try await device.load(DraftPreview.self, DraftPreviewQuery(draft: QuestDraft(name: "Draft", strictness: .goal, recurrence: try ReadsDevice.daily(from: today))))
      ),
      String(reflecting: try await device.load(HeroDeck.self, HeroDeckQuery(eventLimit: 100))),
      String(reflecting: try await device.load(ComingBack.self, ComingBackQuery())),
    ]
    #expect(dumps[2].contains("Marker Quest Zq"), "the dump would show a value that reached the model")
    for (index, dump) in dumps.enumerated() {
      #expect((Self.healthValues + Self.activityValues).filter { dump.contains($0) } == [], "model \(index)")
    }
    for kind in [MemoirStoreKind.activity, .restricted] {
      let board = try await stores.store(kind).read { transaction in try TodayBoard.load(TodayBoardQuery(date: today), in: transaction) }
      #expect(board.occurrences.isEmpty && board.openDay == nil, "a store without the projection reads as empty")
    }
  }
}

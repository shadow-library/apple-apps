import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("BodyAndHealthModel", TestTimeLimit.standard)
struct BodyAndHealthModelTests {
  private static let english = Locale(identifier: "en_GB")

  private func model(_ context: MemoirScreenContext) -> BodyAndHealthModel {
    let health = HealthReadingModel(environment: LogTesting.environment(.otherPlatform, device: nil), stores: context.stores, clock: context.clock)
    return BodyAndHealthModel(context: context, health: health, locale: Self.english)
  }

  private func series(_ builtin: BuiltinMetric, in model: BodyAndHealthModel) throws -> MetricSeries {
    try #require(model.overview.state.value?.series.first { $0.metric.builtin == builtin })
  }

  @Test("should keep each metric's day in the store of its class, with no command for an activity or health value")
  func savesEntriesByClass() async throws {
    let context = try QuestsTesting.context()
    let model = model(context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the metrics load") { model.overview.state.value != nil }
      let steps = try series(.steps, in: model)
      let water = try series(.water, in: model)
      model.entries[steps.metric.reference.id] = "9000"
      #expect(await model.saveEntry(steps))
      model.entries[water.metric.reference.id] = "2.25"
      #expect(await model.saveEntry(water))
      try await TestClock.until("both days show") { (try? series(.water, in: model).today) != nil && (try? series(.steps, in: model).today) != nil }
      #expect(try series(.water, in: model).today?.value == DecimalText("2250"))
      #expect(model.entry(for: try series(.water, in: model)) == "2.25", "the field shows the stored day again in litres")
      model.entries[water.metric.reference.id] = "lots"
      #expect(await model.saveEntry(try series(.water, in: model)) == false)
      #expect(model.problems[water.metric.reference.id] != nil)
      #expect(model.entry(for: try series(.water, in: model)) == "lots", "what the owner typed stays to be fixed")
      #expect(try await LogTesting.count(.activityMetricDay, in: context.stores.activity) == 1)
      #expect(try await LogTesting.count(.healthMetricDay, in: context.stores.restricted) == 1)
      #expect(try await LogTesting.bodies(in: context).isEmpty, "activity and health values append no command")

      #expect(await model.clearEntry(try series(.steps, in: model)))
      try await TestClock.until("the steps clear") { (try? series(.steps, in: model).today) == nil }
    }
  }

  @Test("should create a metric as health data unless told otherwise, edit, move and delete it, and leave built-ins alone")
  func managesMetrics() async throws {
    let context = try QuestsTesting.context()
    let model = model(context)
    var draft = MetricDraft()
    draft.name = "Glucose"
    draft.unit = "mmol/L"

    #expect(await model.create(draft))
    #expect(try await LogTesting.count(.healthMetric, in: context.stores.restricted) == 1)
    #expect(try await LogTesting.count(.generalMetric, in: context.stores.main) == 0)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the metric shows") { model.overview.state.value?.series.contains { $0.metric.name == "Glucose" } == true }
      let glucose = try #require(model.overview.state.value?.series.first { $0.metric.name == "Glucose" }?.metric)
      var renamed = MetricDraft(glucose)
      renamed.name = "Blood glucose"
      #expect(await model.update(glucose, to: renamed))
      var moved = renamed
      moved.syncClass = .general
      #expect(await model.update(glucose, to: moved))
      try await TestClock.until("the metric moves") { model.overview.state.value?.series.contains { $0.metric.reference.metricClass == .general } == true }
      let general = try #require(model.overview.state.value?.series.first { $0.metric.reference.metricClass == .general }?.metric)
      #expect(general.name == "Blood glucose")
      #expect(await model.delete(general))
      let steps = try series(.steps, in: model).metric
      #expect(await model.delete(steps) == false)
      #expect(await model.update(steps, to: MetricDraft(steps)) == false)
    }

    let types = try await LogTesting.commands(in: context).map(\.type.name)
    #expect(types == ["metric.create", "metric.update", "metric.create", "metric.delete", "metric.update", "metric.delete"])
  }

  @Test("should offer a quest whose threshold the day crosses and complete it only through the quest actions when the owner accepts")
  func completesAThresholdOffer() async throws {
    let context = try QuestsTesting.context()
    let quest = try await QuestsTesting.quest("Walk 8,000 steps", strictness: .goal, start: nil, in: context)
    let value = try #require(DecimalText("8000"))
    try await QuestThresholds.set(QuestThreshold(quest: quest, metric: BuiltinMetric.steps.reference, value: value, comparison: .atLeast), in: context.stores)
    let model = model(context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the metrics load") { model.overview.state.value != nil }
      #expect(model.overview.state.value?.offers.isEmpty == true)
      let steps = try series(.steps, in: model)
      model.entries[steps.metric.reference.id] = "9100"
      #expect(await model.saveEntry(steps))
      try await TestClock.until("the offer shows") { model.overview.state.value?.offers.count == 1 }
      let offer = try #require(model.overview.state.value?.offers.first)
      let overview = try #require(model.overview.state.value)
      #expect(offer.quest == quest && offer.date == TestClock.day0 && model.offers(for: steps.metric, in: overview) == [offer])
      #expect(try await LogTesting.bodies(in: context).count == 1, "an offer writes nothing")

      await model.complete(offer)

      #expect(model.offerFeedback?.isFailure == false)
      let occurrence = Occurrence(quest: quest, date: TestClock.day0)
      #expect(try await LogTesting.bodies(in: context).last == .questComplete(occurrence))
      try await TestClock.until("the offer goes once the occurrence is logged") { model.overview.state.value?.offers.isEmpty == true }

      await model.complete(offer)
      #expect(model.offerFeedback?.isFailure == true, "a quest already completed is not completed again")
      #expect(try await LogTesting.bodies(in: context).filter { $0 == .questComplete(occurrence) }.count == 1)
    }
  }

  @Test("should keep every activity and health value out of the main database file")
  func keepsHealthOutOfTheMainFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MemoirTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try MemoirVault(directory: directory)
    let clock = TestClock(day: 0, minute: 720)
    let context = MemoirScreenContext(try await MemoirVaultOpener.open(.vault(vault), appVersion: "1", clock: clock.memoir(deviceZone: TestClock.utc)))
    let weight = WeightModel(context: context, preference: WeightUnitPreference(suiteName: LogTesting.suite()), locale: Self.english)
    weight.unit = .kilograms
    weight.input = "83.47"
    #expect(await weight.save())
    let model = model(context)
    var health = MetricDraft()
    health.name = "Glucosamine Xq"
    #expect(await model.create(health))
    var activity = MetricDraft()
    activity.name = "Pacing Marker Zq"
    activity.syncClass = .activity
    #expect(await model.create(activity))
    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the metrics load") { model.overview.state.value != nil }
      let heart = try series(.restingHeartRate, in: model)
      model.entries[heart.metric.reference.id] = "61.37"
      #expect(await model.saveEntry(heart))
    }

    let markers = ["83.47", "61.37", "Glucosamine Xq", "Pacing Marker Zq"]
    let main = try Self.bytes(of: vault.databaseURL(.main))
    #expect(markers.filter { main.range(of: Data($0.utf8)) != nil }.isEmpty)
    let elsewhere = try Self.bytes(of: vault.databaseURL(.restricted)) + Self.bytes(of: vault.databaseURL(.activity))
    #expect(markers.filter { elsewhere.range(of: Data($0.utf8)) == nil }.isEmpty, "the values were written, to the stores of their class")
  }

  private static func bytes(of database: URL) throws -> Data {
    var bytes = Data()
    for suffix in ["", "-wal", "-shm"] {
      let url = URL(fileURLWithPath: database.path(percentEncoded: false) + suffix)
      if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { bytes.append(try Data(contentsOf: url, options: .uncached)) }
    }
    return bytes
  }
}

import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("WeightModel", TestTimeLimit.standard)
struct WeightModelTests {
  private static let english = Locale(identifier: "en_GB")

  private func model(_ context: MemoirScreenContext, suite: String = LogTesting.suite()) -> WeightModel {
    let preference = WeightUnitPreference(suiteName: suite)
    preference.unit = .kilograms
    return WeightModel(context: context, preference: preference, locale: Self.english)
  }

  private func weight(on date: LocalDate, in context: MemoirScreenContext) async throws -> WeightRecord? {
    try await context.stores.restricted.read { transaction in try WeightRecord.read(key: .weight(date), in: transaction).entry?.record }
  }

  @Test("should save the day's weight in the restricted store with only weight.save in the main store")
  func savesAWeight() async throws {
    let context = try QuestsTesting.context()
    let model = model(context)
    model.input = "72.4"

    #expect(await model.save())

    #expect(try await weight(on: TestClock.day0, in: context)?.kilograms == DecimalText("72.4"))
    #expect(try await LogTesting.bodies(in: context) == [.weightSave(WeightEntry(date: TestClock.day0))])
    #expect(model.input.isEmpty && model.confirmation != nil)
  }

  @Test("should ask before replacing the day's weight and replace it only once confirmed")
  func asksBeforeReplacing() async throws {
    let context = try QuestsTesting.context()
    let model = model(context)
    model.input = "72.4"
    #expect(await model.save())
    model.input = "72.9"

    #expect(await model.save() == false)

    let asked = try #require(model.replacement)
    #expect(asked.existing.kilograms == DecimalText("72.4") && asked.kilograms == DecimalText("72.9"))
    #expect(try await weight(on: TestClock.day0, in: context)?.kilograms == DecimalText("72.4"), "asking writes nothing")
    model.cancelReplacement()
    #expect(await model.save(confirmingReplacement: true) == false, "a cancelled question confirms nothing")
    #expect(await model.save() == false)

    #expect(await model.save(confirmingReplacement: true))

    #expect(model.replacement == nil)
    #expect(try await weight(on: TestClock.day0, in: context)?.kilograms == DecimalText("72.9"))
    #expect(model.replaced[TestClock.day0] == DecimalText("72.4"))
    #expect(
      try await LogTesting.bodies(in: context) == [
        .weightSave(WeightEntry(date: TestClock.day0)), .weightSave(WeightEntry(date: TestClock.day0, confirmedReplacement: true)),
      ])
  }

  @Test("should save a weight whose earlier save never reached the main store without asking")
  func repairsAnOrphanedWeight() async throws {
    let context = try QuestsTesting.context()
    let orphan = WeightRecord(date: TestClock.day0, kilograms: try #require(DecimalText("70")), loggedAtMillis: 1)
    _ = try await context.stores.restricted.write { transaction in try orphan.create(in: &transaction) }
    let model = model(context)
    model.input = "71.2"

    #expect(await model.save())

    #expect(model.replacement == nil)
    #expect(try await weight(on: TestClock.day0, in: context)?.kilograms == DecimalText("71.2"))
    #expect(try await LogTesting.bodies(in: context) == [.weightSave(WeightEntry(date: TestClock.day0))])
  }

  @Test("should read pounds into kilograms, keep the unit on the device and refuse a weight outside 30 to 250 kg")
  func readsTheOwnersUnit() async throws {
    let context = try QuestsTesting.context()
    let suite = LogTesting.suite()
    let model = model(context, suite: suite)
    model.unit = .pounds
    #expect(WeightUnitPreference(suiteName: suite).unit == .pounds)

    model.input = "60"
    #expect(await model.save() == false)
    #expect(model.problem?.contains("lb") == true)
    model.input = "a lot"
    #expect(await model.save() == false)
    #expect(model.problem == String(localized: "Use digits only, like 72.4.", table: "Log"))
    model.input = ""
    #expect(await model.save() == false)
    #expect(model.problem == String(localized: "Enter a weight to save.", table: "Log"))
    model.input = "160"
    #expect(await model.save())

    #expect(try await weight(on: TestClock.day0, in: context)?.kilograms == DecimalText("72.57"))
    #expect(model.problem == nil)
  }

  @Test("should show the 7-day average and the 90-day change from the restricted store")
  func showsTheTrend() async throws {
    let context = try QuestsTesting.context()
    for (back, kilograms) in [(10, "74"), (3, "73"), (0, "72")] {
      let record = WeightRecord(date: TestClock.day(-back), kilograms: try #require(DecimalText(kilograms)), loggedAtMillis: 1)
      _ = try await context.stores.restricted.write { transaction in try record.create(in: &transaction) }
    }
    let model = model(context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the weight loads") { model.overview.state.value != nil }
      let overview = try #require(model.overview.state.value)
      #expect(overview.sevenDayAverage == Fraction(numerator: 145, denominator: 2))
      #expect(overview.ninetyDayChange == DecimalText("-2"))
      #expect(overview.today?.kilograms == DecimalText("72"))
    }
  }
}

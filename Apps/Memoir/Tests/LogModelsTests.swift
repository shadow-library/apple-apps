import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Journal, meals and side quests", TestTimeLimit.standard)
struct LogModelsTests {
  @Test("should save today's entry with its mood as journal.save and the entry in the main store, then show it")
  func savesAJournalEntry() async throws {
    let context = try QuestsTesting.context()
    let model = JournalModel(context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the journal loads") { model.overview.state.value != nil }
      #expect(await model.save() == false, "a blank entry is not saved")
      model.text = "Walked to the **river**."
      model.toggleMood(4)
      model.toggleMood(4)
      #expect(model.mood == nil, "pressing the selected mood clears it")
      model.toggleMood(5)

      #expect(await model.save())

      let bodies = try await LogTesting.bodies(in: context)
      guard case .journalSave(let entry) = try #require(bodies.last) else { throw TestFailure("expected journal.save, got \(bodies)") }
      #expect(entry.date == TestClock.day0)
      let record = try await context.stores.main.read { transaction in try JournalEntryRecord.read(id: entry.id, in: transaction).entry?.record }
      #expect(record?.text == "Walked to the **river**." && record?.mood == 5)
      #expect(model.text.isEmpty && model.mood == nil && model.confirmation != nil)
      try await TestClock.until("the entry shows") { model.overview.state.value?.today?.entry.id == entry.id }
      #expect(model.overview.state.value?.today?.wordCount == 4)
    }
  }

  @Test("should keep the text and mood and say why when the entry is refused")
  func keepsARefusedEntry() async throws {
    let context = try QuestsTesting.context()
    let model = JournalModel(context: context)
    model.text = "Kept"
    model.mood = 9

    #expect(await model.save() == false)

    #expect(model.failure != nil && model.confirmation == nil)
    #expect(model.text == "Kept" && model.mood == 9)
    #expect(try await LogTesting.bodies(in: context).isEmpty)
  }

  @Test("should search entries without regard to case and page them twenty at a time")
  func searchesAndPagesEntries() async throws {
    let context = try QuestsTesting.context()
    let model = JournalModel(context: context)
    for index in 0..<21 {
      model.text = index == 3 ? "The RIVER again" : "Entry \(index)"
      #expect(await model.save())
    }

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the entries load") { model.overview.state.value?.entries.count == 21 }
      let overview = try #require(model.overview.state.value)
      #expect(model.visibleCount == 20)
      model.showMore()
      #expect(model.visibleCount == 40)
      model.search = "river"
      #expect(model.visibleCount == 20, "a new search starts from the first page")
      #expect(model.entries(in: overview).map(\.entry.text) == ["The RIVER again"])
    }
  }

  @Test("should log a typed meal with zero calories, and refuse one without calories or a name")
  func logsATypedMeal() async throws {
    let context = try QuestsTesting.context()
    let model = MealsModel(context: context)
    model.draft.name = "Black coffee"
    model.draft.calories = nil
    #expect(await model.saveMeal() == false)
    #expect(model.draft.caloriesProblem != nil)
    model.draft.calories = 0

    #expect(await model.saveMeal())

    let bodies = try await LogTesting.bodies(in: context)
    guard case .mealLog(let entry) = try #require(bodies.last) else { throw TestFailure("expected meal.log, got \(bodies)") }
    let meal = try await context.stores.main.read { transaction in try MealRecord.read(id: entry.id, in: transaction).entry?.record }
    #expect(meal?.name == "Black coffee" && meal?.calories == 0 && meal?.mealType == .known(.cooked) && meal?.preset == nil)
    #expect(model.draft == MealDraft(), "the form starts again")
    model.draft.name = "   "
    #expect(await model.saveMeal() == false)
    #expect(try await LogTesting.bodies(in: context).count == 1)
  }

  @Test("should create, edit and delete a preset with its commands, and log a preset's numbers as they were")
  func managesPresets() async throws {
    let context = try QuestsTesting.context()
    let model = MealsModel(context: context)
    var draft = MealDraft()
    draft.name = "Porridge"
    draft.calories = 350
    #expect(await model.savePreset(draft, editing: nil))
    let created = try #require(try await context.stores.main.read { transaction in try MealPresetRecord.listing(in: transaction).entries.first?.record })

    #expect(await model.logPreset(created) == .logged)
    var edited = MealDraft(created)
    edited.calories = 400
    edited.mealType = .ateOut
    #expect(await model.savePreset(edited, editing: created))
    #expect(await model.deletePreset(created))

    let bodies = try await LogTesting.bodies(in: context)
    let reference = RecordReference(id: created.id)
    guard case .mealLogPreset(let logged) = bodies[1] else { throw TestFailure("expected meal.logPreset, got \(bodies)") }
    #expect(bodies.count == 4)
    #expect(bodies[0] == .mealSavePreset(reference) && bodies[2] == .mealPresetUpdate(reference) && bodies[3] == .mealPresetDelete(reference))
    #expect(logged.presetId == created.id)
    let (meal, preset) = try await context.stores.main.read { transaction in
      (try MealRecord.read(id: logged.id, in: transaction).entry?.record, try MealPresetRecord.read(id: created.id, in: transaction).entry)
    }
    #expect(meal?.calories == 350 && meal?.preset == created.id, "the meal keeps the numbers it was logged with")
    #expect(preset?.isRemoved == true && preset?.record.calories == 400)
  }

  @Test("should ask for a second tap before logging the same preset again within moments")
  func guardsARepeatedPreset() async throws {
    let context = try QuestsTesting.context()
    let start = ContinuousClock.now
    let offset = Recorded<Duration>()
    offset.append(.zero)
    let model = MealsModel(context: context) { start + (offset.values.last ?? .zero) }
    var draft = MealDraft()
    draft.name = "Skyr"
    draft.calories = 120
    #expect(await model.savePreset(draft, editing: nil))
    let preset = try #require(try await context.stores.main.read { transaction in try MealPresetRecord.listing(in: transaction).entries.first?.record })

    #expect(await model.logPreset(preset) == .logged)
    offset.append(.milliseconds(500))
    #expect(await model.logPreset(preset) == .confirmRelog)
    #expect(model.confirmingPreset == preset.id)
    offset.append(.milliseconds(700))
    #expect(await model.logPreset(preset) == .ignored, "a second tap that lands at once is a bounce")
    offset.append(.milliseconds(1_000))
    #expect(await model.logPreset(preset) == .logged)
    #expect(model.confirmingPreset == nil)
    offset.append(.milliseconds(10_000))
    #expect(await model.logPreset(preset) == .logged, "long after the last one there is nothing to confirm")

    let logs = try await LogTesting.bodies(in: context).filter { if case .mealLogPreset = $0 { true } else { false } }
    #expect(logs.count == 3)
  }

  @Test("should log a side quest with its stat, and show only the day's first three as rewarded")
  func logsSideQuests() async throws {
    let context = try QuestsTesting.context()
    let model = SideQuestsModel(context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the side quests load") { model.overview.state.value != nil }
      model.stat = .mind
      for index in 1...4 {
        model.name = "Act \(index)"
        #expect(await model.save())
      }
      #expect(model.name.isEmpty)
      try await TestClock.until("replay rewards the side quests") { model.overview.state.value?.items.count == 4 && model.overview.state.value?.rewardedToday == 3 }
      let overview = try #require(model.overview.state.value)
      #expect(overview.items.filter(\.rewarded).count == 3)
      #expect(overview.isRewardCapReached)
      #expect(model.items(in: overview).count == 4)
      model.search = "act 4"
      #expect(model.items(in: overview).map(\.sideQuest.name) == ["Act 4"])
    }
    let bodies = try await LogTesting.bodies(in: context)
    #expect(bodies.allSatisfy { if case .sideQuestLog(let entry) = $0 { entry.statAffinity == .mind } else { false } })
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

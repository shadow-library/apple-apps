import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("QuestDetailModel", TestTimeLimit.standard)
struct QuestDetailModelTests {
  @Test("should load the quest's summary, today's occurrence, totals, load and that it has no threshold")
  func loadsTheDetail() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = QuestDetailModel(questID: id, context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the detail and threshold load") { model.detail.state.value != nil && model.threshold.state.value != nil }
      let detail = try #require(model.detail.state.value)
      #expect(detail.summary?.quest.name == "Walk")
      #expect(detail.today?.status == .open)
      #expect(detail.today?.occurrence == Occurrence(quest: id, date: TestClock.day0))
      #expect(detail.load?.weeklyMinutes == Fraction(7 * 30))
      #expect(detail.scheduleEdit == .available)
      #expect(model.threshold.state.value == .some(nil))
      #expect(model.canDelete)
    }
  }

  @Test("should say a quest replay does not know is missing")
  func reportsAMissingQuest() async throws {
    let context = try QuestsTesting.context()
    let model = QuestDetailModel(questID: UUID(), context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the detail loads") { model.detail.state.value != nil }
      #expect(model.detail.state.value?.summary == nil)
      #expect(!model.canDelete)
    }
  }

  @Test("should delete only after asking, issuing quest.delete and keeping the quest inactive with its record")
  func deletesAfterConfirmation() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = QuestDetailModel(questID: id, context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the detail loads") { model.detail.state.value?.summary != nil }
      #expect(await model.delete() == false, "nothing was asked to be confirmed")
      model.requestDelete()
      model.cancelDelete()
      #expect(await model.delete() == false, "the owner cancelled")
      #expect(try await QuestsTesting.bodies(in: context).count == 1)
      model.requestDelete()
      #expect(model.isConfirmingDelete)
      #expect(try await QuestsTesting.bodies(in: context).count == 1, "asking writes nothing")
      model.isConfirmingDelete = false

      #expect(await model.delete())
      #expect(try await QuestsTesting.bodies(in: context).last == .questDelete(QuestReference(questId: id)))
      try await TestClock.until("the quest turns inactive") { model.detail.state.value?.summary?.quest.isActive == false }
      #expect(try await QuestsTesting.record(id, in: context)?.name == "Walk")
      #expect(!model.canDelete)
      #expect(await model.delete() == false)
      #expect(try await QuestsTesting.bodies(in: context).count == 2, "an inactive quest is not deleted again")
    }
  }

  @Test("should show the threshold the builder set, from the activity store")
  func showsTheThreshold() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = QuestDetailModel(questID: id, context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("no threshold yet") { model.threshold.state.value == .some(nil) }
      try await QuestThresholds.set(try #require(QuestThresholdSummary.standard(for: id)), in: context.stores)
      try await TestClock.until("the threshold shows") { model.threshold.state.value == .some(QuestThresholdSummary.standard) }
      try await QuestThresholds.clear(quest: id, in: context.stores)
      try await TestClock.until("the threshold goes") { model.threshold.state.value == .some(nil) }
    }
  }
}

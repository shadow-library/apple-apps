import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("QuestListModel", TestTimeLimit.standard)
struct QuestListModelTests {
  @Test("should list nothing and say so before any quest exists")
  func listsNothingAtFirst() async throws {
    let context = try QuestsTesting.context()
    let model = QuestListModel(context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the listing loads") { model.listing.state.value != nil }
      let listing = try #require(model.listing.state.value)
      #expect(listing.all.entries.isEmpty)
      #expect(listing.inFilter == 0)
    }
  }

  @Test("should keep active quests by default and move a deleted one to Inactive with its history")
  func filtersActiveAndInactive() async throws {
    let context = try QuestsTesting.context()
    let walk = try await QuestsTesting.quest("Walk", in: context)
    let read = try await QuestsTesting.quest("Read 20 pages", in: context)
    try await context.writer.issue(.questDelete(QuestReference(questId: read)))
    let model = QuestListModel(context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the active list loads") { model.listing.state.value?.shown.entries.map(\.id) == [walk] }
      #expect(model.listing.state.value?.inFilter == 1)
    }
    model.filter = .inactive
    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the inactive list loads") { model.listing.state.value?.shown.filter == .inactive }
      #expect(model.listing.state.value?.shown.entries.map(\.id) == [read])
      #expect(model.listing.state.value?.shown.entries.first?.quest.isActive == false)
    }
    model.filter = .all
    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("every quest loads") { model.listing.state.value?.shown.filter == .all }
      #expect(Set(model.listing.state.value?.shown.entries.map(\.id) ?? []) == [walk, read])
      #expect(model.listing.state.value?.inFilter == 2)
    }
  }

  @Test("should search names ignoring case and accents, and count the filter's quests before the search narrows them")
  func searchesNames() async throws {
    let context = try QuestsTesting.context()
    let cafe = try await QuestsTesting.quest("Café run", in: context)
    try await QuestsTesting.quest("Stretch", in: context)
    let model = QuestListModel(context: context)
    model.search = "  CAFE "

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the search applies") { model.listing.state.value?.shown.search == "  CAFE " }
      let listing = try #require(model.listing.state.value)
      #expect(listing.isSearching)
      #expect(listing.shown.entries.map(\.id) == [cafe])
      #expect(listing.inFilter == 2)
    }
  }

  @Test("should show a quest written after the list opened")
  func followsWrites() async throws {
    let context = try QuestsTesting.context()
    let model = QuestListModel(context: context)

    try await QuestsObservation { await model.observe() }.during {
      try await TestClock.until("the empty list loads") { model.listing.state.value != nil }
      let id = try await QuestsTesting.quest("Walk", in: context)
      try await TestClock.until("the new quest shows") { model.listing.state.value?.shown.entries.map(\.id) == [id] }
    }
  }
}

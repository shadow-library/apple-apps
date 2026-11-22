import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("PlanBoardModel", TestTimeLimit.standard)
struct PlanBoardModelTests {
  private static func start(_ model: PlanBoardModel) async throws {
    try await TestClock.until("today is known") { model.today != nil }
  }

  @Test("should show the week holding today, its loads, and offer to lock today's scheduled quests")
  func loadsTheWeek() async throws {
    let context = try QuestsTesting.context()
    let walk = try await QuestsTesting.quest("Walk", duration: 30, in: context)
    let read = try await QuestsTesting.quest("Read", start: nil, duration: 20, in: context)
    let model = PlanBoardModel(context: context)

    try await QuestsObservation { await model.followToday() }.during {
      try await Self.start(model)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the board loads") { model.snapshot.state.value != nil }
        let board = try #require(model.snapshot.state.value?.board)
        #expect(board.days.count == 7)
        let today = try #require(board.days.first { $0.date == TestClock.day0 })
        #expect(today.load.minutes == 50 && today.load.occurrences == 2)
        #expect(model.lockControl == .lock(quests: [walk, read], availability: .available, capacity: model.snapshot.state.value?.openDay?.lock.capacity))
      }
    }
  }

  @Test("should issue plan.setLock for today's quests, then offer to unlock and issue the unlock")
  func locksAndUnlocks() async throws {
    let context = try QuestsTesting.context()
    let walk = try await QuestsTesting.quest("Walk", in: context)
    let model = PlanBoardModel(context: context)

    try await QuestsObservation { await model.followToday() }.during {
      try await Self.start(model)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the lock is offered") { model.lockControl.availability == .available }
        #expect(await model.toggleLock())
        #expect(try await QuestsTesting.bodies(in: context).last == .planSetLock(try PlanLock(locking: [walk])))

        try await TestClock.until("the unlock is offered") { model.lockControl == .unlock(availability: .available) }
        #expect(model.snapshot.state.value?.board.days.first { $0.date == TestClock.day0 }?.lockNote == .locked)
        #expect(await model.toggleLock())
        #expect(try await QuestsTesting.bodies(in: context).last == .planSetLock(.unlocked))
      }
    }
  }

  @Test("should not issue a lock when nothing is scheduled today")
  func refusesAnEmptyLock() async throws {
    let context = try QuestsTesting.context()
    try await QuestsTesting.quest("Sunday reset", frequency: .weekly([.sunday]), in: context)
    let model = PlanBoardModel(context: context)

    try await QuestsObservation { await model.followToday() }.during {
      try await Self.start(model)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the board loads") { model.snapshot.state.value != nil }
        #expect(model.lockControl.availability == .unavailable(.nothingToLock))
        #expect(await model.toggleLock() == false)
        #expect(try await QuestsTesting.bodies(in: context).count == 1)
      }
    }
  }

  @Test("should offer no lock for another week or the month")
  func hidesTheLockAwayFromToday() async throws {
    let context = try QuestsTesting.context()
    try await QuestsTesting.quest("Walk", in: context)
    let model = PlanBoardModel(context: context)

    try await QuestsObservation { await model.followToday() }.during {
      try await Self.start(model)
      model.step(1)
      #expect(model.anchor == TestClock.day(7))
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("next week loads") { model.snapshot.state.value?.board.days.first?.date ?? TestClock.day0 > TestClock.day0 }
        #expect(model.lockControl == .notThisWeek)
        #expect(await model.toggleLock() == false)
      }
      model.showToday()
      model.scope = .month
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the month loads") { model.snapshot.state.value?.board.month != nil }
        #expect(model.lockControl == .hidden)
        #expect(await model.toggleLock() == false)
      }
      model.showWeek(of: TestClock.day(3))
      #expect(model.scope == .week && model.anchor == TestClock.day(3))
    }
    #expect(try await QuestsTesting.bodies(in: context).count == 1)
  }

  @Test("should say the plan is empty before any quest")
  func reportsAnEmptyPlan() async throws {
    let context = try QuestsTesting.context()
    let model = PlanBoardModel(context: context)

    try await QuestsObservation { await model.followToday() }.during {
      try await Self.start(model)
      try await QuestsObservation { await model.observe() }.during {
        try await TestClock.until("the board loads") { model.snapshot.state.value != nil }
        #expect(model.snapshot.state.value?.isEmpty == true)
        #expect(model.lockControl == .notThisWeek)
      }
    }
  }
}

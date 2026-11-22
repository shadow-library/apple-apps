import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("QuestActions", TestTimeLimit.standard)
struct QuestActionsTests {
  private static func world(minute: Int = 720) async throws -> (TodayTestWorld, UUID) {
    let world = try await TodayTestWorld(minute: minute)
    let walk = try await world.quest("Walk")
    try await world.start()
    _ = try await world.row(walk, until: "the quest's row")
    return (world, walk)
  }

  @Test("should issue quest.complete for a completion")
  func completes() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)

    #expect(await world.model.perform(.complete(occurrence)) == .done(offersUndo: false))

    #expect(try await world.bodies().last == .questComplete(occurrence))
  }

  @Test("should issue a partial, then attach its reason in the same write, which replay applies to the partial")
  func recordsAPartialWithItsReason() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)

    let outcome = await world.model.perform(.partial(occurrence, QuestActionReason(tag: .tooTired, note: "  Ran out of time ")))

    #expect(outcome == .done(offersUndo: false))
    let attach = MemoirCommandBody.questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: .tooTired, hasNote: true))
    #expect(try await world.bodies().suffix(2) == [.questPartial(occurrence), attach])
    #expect(try await world.note(of: attach) == "Ran out of time")
    let row = try await world.row(walk, until: "the partial with its reason") { $0.log?.reasonTag == .tooTired }
    #expect(row.status == .recorded(.partial))
    #expect(row.log?.reasonNote != nil)
  }

  @Test("should issue a bare partial when no reason is given")
  func recordsABarePartial() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    let before = try await world.bodies().count

    #expect(await world.model.perform(.partial(occurrence, QuestActionReason(tag: nil, note: "   "))) == .done(offersUndo: false))

    let bodies = try await world.bodies()
    #expect(bodies.count == before + 1)
    #expect(bodies.last == .questPartial(occurrence))
  }

  @Test("should issue quest.skip with its reason and note, and offer no undo for a reasoned skip")
  func skipsWithAReason() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)

    #expect(await world.model.perform(.skip(occurrence, QuestActionReason(tag: .travel, note: "On a train"))) == .done(offersUndo: false))

    let skip = MemoirCommandBody.questSkip(QuestBreak(occurrence: occurrence, reasonTag: .travel, hasNote: true))
    #expect(try await world.bodies().last == skip)
    #expect(try await world.note(of: skip) == "On a train")
  }

  @Test("should offer undo after a bare skip of a quest with nothing to lose, and undo it by deleting the log")
  func undoesABareSkip() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)

    #expect(await world.model.perform(.skip(occurrence, .none)) == .done(offersUndo: true))
    _ = try await world.row(walk, until: "the skip") { $0.status == .recorded(.skipped) }

    #expect(await world.model.perform(.undo(occurrence)) == .done(offersUndo: false))

    #expect(try await world.bodies().suffix(2) == [.questSkip(QuestBreak(occurrence: occurrence)), .questDeleteLog(occurrence)])
    _ = try await world.row(walk, until: "the occurrence open again") { $0.status == .open }
  }

  @Test("should refuse to undo a skip that has had a reason attached since, writing nothing")
  func refusesUndoAfterAReason() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    #expect(await world.model.perform(.skip(occurrence, .none)) == .done(offersUndo: true))
    _ = try await world.row(walk, until: "the skip") { $0.log != nil }
    #expect(await world.model.perform(.attachReason(occurrence, QuestActionReason(tag: .forgot, note: ""))) == .done(offersUndo: false))
    _ = try await world.row(walk, until: "the reason") { $0.log?.reasonTag == .forgot }
    let before = try await world.bodies()

    #expect(await world.model.perform(.undo(occurrence)) == .unavailable(.notUndoable))

    #expect(try await world.bodies() == before)
    #expect(try await world.row(walk, until: "the skip kept").status == .recorded(.skipped))
  }

  @Test("should start a new reason from the tag and note it replaces")
  func readsTheReasonItReplaces() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let read = try await world.quest("Read", start: 21 * 60)
    let walkToday = Occurrence(quest: walk, date: TestClock.day0)
    let readToday = Occurrence(quest: read, date: TestClock.day0)
    #expect(await world.model.perform(.skip(walkToday, QuestActionReason(tag: .travel, note: "On a train"))) == .done(offersUndo: false))
    #expect(await world.model.perform(.skip(readToday, QuestActionReason(tag: .tooTired, note: ""))) == .done(offersUndo: false))
    let walked = try await world.row(walk, until: "the reasoned skip") { $0.log?.reasonTag == .travel }
    let skipped = try await world.row(read, until: "the tagged skip") { $0.log?.reasonTag == .tooTired }

    #expect(await world.model.existingReason(of: walked) == QuestActionReason(tag: .travel, note: "On a train"))
    #expect(await world.model.existingReason(of: skipped) == QuestActionReason(tag: .tooTired, note: ""))
    let stretch = try await world.quest("Stretch", strictness: .goal, start: nil)
    #expect(await world.model.existingReason(of: try await world.row(stretch, until: "a row with nothing recorded")) == .none)
  }

  @Test("should ask before a postpone breaks today's locked plan, and offer no undo once it has")
  func confirmsBreakingTheLock() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    try await world.context.writer.issue(.planSetLock(try PlanLock(locking: [walk])))
    let locked = try await world.row(walk, until: "the lock") { $0.locked }
    #expect(locked.actions.postpone == .needsConfirmation(.breaksPlanLock))
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    let before = try await world.bodies()

    #expect(await world.model.perform(.postpone(occurrence, breakingLock: false)) == .unavailable(.needsConfirmation(.breaksPlanLock)))
    #expect(try await world.bodies() == before)

    #expect(await world.model.perform(.postpone(occurrence, breakingLock: true)) == .done(offersUndo: false))
    #expect(try await world.bodies().last == .questPostpone(QuestBreak(occurrence: occurrence)))
    _ = try await world.row(walk, until: "the postpone") { $0.status == .recorded(.postponed) }
    let model = world.model
    try await TestClock.until("the broken lock") { model.snapshot?.board.lock.state == .broken }
    #expect(await world.model.perform(.undo(occurrence)) == .unavailable(.notUndoable), "the postpone broke the lock")
  }

  @Test("should refuse to move today's occurrence to a minute the account's clock has passed, writing nothing")
  func refusesAPastTime() async throws {
    let (world, walk) = try await Self.world(minute: 720)
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    let before = try await world.bodies()

    #expect(await world.model.perform(.reschedule(occurrence, toMinute: 719, acceptBeyondCap: false)) == .unavailable(.timePassed))

    #expect(try await world.bodies() == before)
    #expect(await world.model.perform(.reschedule(occurrence, toMinute: 720, acceptBeyondCap: false)) == .done(offersUndo: false))
  }

  @Test("should not offer undo for a quest with a running streak")
  func keepsUndoFromAStreak() async throws {
    let world = try await TodayTestWorld()
    let walk = try await world.quest("Walk", strictness: .goal, start: nil)
    try await world.start()
    defer { world.stop() }
    _ = try await world.row(walk, until: "the quest's row")
    #expect(await world.model.perform(.complete(Occurrence(quest: walk, date: TestClock.day0))) == .done(offersUndo: false))
    try await world.turn(to: 1)
    _ = try await world.row(walk, until: "a running streak") { $0.streak.currentDays > 0 }

    let outcome = await world.model.perform(.skip(Occurrence(quest: walk, date: TestClock.day(1)), .none))
    #expect(outcome == .done(offersUndo: false), "\(outcome)")
  }

  @Test("should issue quest.postpone, and quest.reschedule with the new minute")
  func postponesAndReschedules() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let read = try await world.quest("Read", start: 21 * 60)
    _ = try await world.row(read, until: "the second quest's row")
    let walkToday = Occurrence(quest: walk, date: TestClock.day0)
    let readToday = Occurrence(quest: read, date: TestClock.day0)

    #expect(await world.model.perform(.postpone(walkToday, breakingLock: false)) == .done(offersUndo: true))
    #expect(await world.model.perform(.reschedule(readToday, toMinute: 22 * 60, acceptBeyondCap: false)) == .done(offersUndo: false))

    #expect(
      try await world.bodies().suffix(2) == [
        .questPostpone(QuestBreak(occurrence: walkToday)), .questReschedule(try QuestReschedule(occurrence: readToday, toMinute: 22 * 60)),
      ])
    let row = try await world.row(read, until: "the move") { $0.status == .recorded(.rescheduled) }
    #expect(row.plannedMinute == 22 * 60)
  }

  @Test("should attach a reason to a recorded outcome")
  func attachesAReason() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    #expect(await world.model.perform(.attachReason(occurrence, QuestActionReason(tag: .forgot, note: ""))) == .unavailable(.blocked(.nothingRecorded)))
    #expect(await world.model.perform(.skip(occurrence, .none)) == .done(offersUndo: true))
    _ = try await world.row(walk, until: "the skip") { $0.log != nil }

    #expect(await world.model.perform(.attachReason(occurrence, QuestActionReason(tag: .forgot, note: ""))) == .done(offersUndo: false))

    #expect(try await world.bodies().last == .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: .forgot, hasNote: false)))
  }

  @Test("should issue nothing for an action the board does not allow")
  func neverIssuesABlockedAction() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let stretch = try await world.quest("Stretch", strictness: .optional, start: nil)
    _ = try await world.row(stretch, until: "the optional quest's row")
    let today = Occurrence(quest: walk, date: TestClock.day0)
    #expect(await world.model.perform(.complete(today)) == .done(offersUndo: false))
    _ = try await world.row(walk, until: "the completion") { $0.log != nil }
    let before = try await world.bodies()

    #expect(await world.model.perform(.complete(today)) == .unavailable(.blocked(.alreadyRecorded(.late))))
    #expect(await world.model.perform(.skip(today, .none)) == .unavailable(.blocked(.alreadyRecorded(.late))))
    #expect(
      await world.model.perform(.postpone(Occurrence(quest: stretch, date: TestClock.day0), breakingLock: true))
        == .unavailable(.blocked(.notAllowedFor(.optional))))
    #expect(
      await world.model.perform(.reschedule(Occurrence(quest: stretch, date: TestClock.day0), toMinute: 900, acceptBeyondCap: false))
        == .unavailable(.blocked(.notAllowedFor(.optional))))
    #expect(await world.model.perform(.complete(Occurrence(quest: walk, date: TestClock.day(1)))) == .unavailable(.blocked(.notYetBegun)))
    #expect(await world.model.perform(.complete(Occurrence(quest: UUID(), date: TestClock.day0))) == .unavailable(.gone))
    #expect(await world.model.actions.perform(.complete(today), on: nil, at: nil) == .unavailable(.gone))

    #expect(try await world.bodies() == before)
  }

  @Test("should ask before a reschedule past the weekly cap, and record it as accepted once confirmed")
  func confirmsBeyondTheCap() async throws {
    let (world, walk) = try await Self.world(minute: 6 * 60)
    defer { world.stop() }
    #expect(await world.model.perform(.reschedule(Occurrence(quest: walk, date: TestClock.day0), toMinute: 600, acceptBeyondCap: false)) == .done(offersUndo: false))
    try await world.turn(to: 1, minute: 6 * 60)
    #expect(await world.model.perform(.reschedule(Occurrence(quest: walk, date: TestClock.day(1)), toMinute: 600, acceptBeyondCap: false)) == .done(offersUndo: false))
    try await world.turn(to: 2, minute: 6 * 60)
    let capped = try await world.row(walk, until: "the cap") { $0.reschedule.isCapReached }
    guard case .needsConfirmation(.rescheduleBecomesPostpone) = capped.actions.reschedule else {
      Issue.record("expected a confirmation, got \(capped.actions.reschedule)")
      return
    }
    let occurrence = Occurrence(quest: walk, date: TestClock.day(2))
    let before = try await world.bodies()

    let unconfirmed = await world.model.perform(.reschedule(occurrence, toMinute: 600, acceptBeyondCap: false))

    guard case .unavailable(.needsConfirmation(.rescheduleBecomesPostpone)) = unconfirmed else {
      Issue.record("expected a confirmation, got \(unconfirmed)")
      return
    }
    #expect(try await world.bodies() == before)
    #expect(await world.model.perform(.reschedule(occurrence, toMinute: 600, acceptBeyondCap: true)) == .done(offersUndo: false))
    #expect(try await world.bodies().last == .questReschedule(try QuestReschedule(occurrence: occurrence, toMinute: 600, acceptBeyondCap: true)))
    _ = try await world.row(walk, until: "the postpone") { $0.status == .recorded(.postponed) }
  }

  @Test("should present a failed write in the reference's words, mark the row unsaved and clear it after the next success")
  func presentsFailures() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    let occurrence = Occurrence(quest: walk, date: TestClock.day0)
    #expect(await world.model.perform(.skip(occurrence, .none)) == .done(offersUndo: true))
    _ = try await world.row(walk, until: "the skip") { $0.log != nil }
    let before = try await world.bodies()

    let outcome = await world.model.perform(.attachReason(occurrence, QuestActionReason(tag: nil, note: String(repeating: "a", count: 121))))

    guard case .failed(let error) = outcome else {
      Issue.record("expected a failure, got \(outcome)")
      return
    }
    #expect(error.headline == String(localized: "Some of the details weren’t valid.", table: "Writing"))
    #expect(world.model.actions.unsaved == [occurrence])
    #expect(try await world.bodies() == before)
    #expect(
      QuestActionCopy.failure(.attachReason, name: "Walk", message: error.headline)
        == String(localized: "Couldn’t save the reason for ‘Walk’: \(error.headline)", table: "Today"))

    #expect(await world.model.perform(.attachReason(occurrence, QuestActionReason(tag: .other, note: ""))) == .done(offersUndo: false))
    #expect(world.model.actions.unsaved.isEmpty)
  }

  @Test("should keep the day's Recovery quest with its reflection, and refuse it once kept")
  func keepsTheRecoveryQuest() async throws {
    let (world, walk) = try await Self.world()
    defer { world.stop() }
    try await world.turn(to: 1)
    let model = world.model
    try await TestClock.until("the Recovery quest") { model.snapshot?.board.recovery?.state == .pending }
    #expect(try world.snapshot.board.recovery?.sourceQuest == walk)

    #expect(await model.completeRecovery(reflection: "  A short walk instead ") == .done(offersUndo: false))

    let body = MemoirCommandBody.recoveryComplete(RecoveryCompletion(hasReflection: true))
    #expect(try await world.bodies().last == body)
    #expect(try await world.note(of: body) == "A short walk instead")
    try await TestClock.until("the Recovery quest kept") { model.snapshot?.board.recovery?.state == .completed }
    #expect(await model.completeRecovery(reflection: "") == .unavailable(.blocked(.recoveryClosed(.completed))))
  }

  @Test("should word each blocked action as the reference does")
  func wordsBlockedActions() {
    #expect(QuestActionCopy.blocked(.alreadyRecorded(.skipped), for: .complete) == String(localized: "Already recorded as skipped.", table: "Today"))
    #expect(QuestActionCopy.blocked(.notAllowedFor(.goal), for: .reschedule) == String(localized: "Reschedule doesn’t apply to this strictness.", table: "Today"))
    #expect(QuestActionCopy.blocked(.notAllowedFor(.optional), for: .postpone) == String(localized: "Postpone does not apply to this strictness.", table: "Today"))
    #expect(QuestActionCopy.blocked(.notYetBegun, for: .complete) == String(localized: "That day hasn’t started yet.", table: "Today"))
    #expect(QuestActionCopy.unavailable(.editWindowClosed, for: .attachReason) == String(localized: "Entries older than 7 days can’t be changed.", table: "Today"))
    #expect(QuestActionCopy.unavailable(.needsConfirmation(.breaksPlanLock), for: .postpone) == nil)
  }
}

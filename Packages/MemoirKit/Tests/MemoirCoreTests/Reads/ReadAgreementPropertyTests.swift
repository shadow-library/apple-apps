import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir read models agree with replay", TestTimeLimit.property)
struct ReadAgreementPropertyTests {
  /// Blocks the client adds on top of replay, which replay itself would take.
  private static func isPolicy(_ block: ActionBlock) -> Bool {
    switch block {
    case .dayPassed, .nothingToLock, .notLocked, .lockedInTodaysPlan: true
    default: false
    }
  }

  private struct Tally {
    var offered = 0
    var blocked = 0
    var mismatches = [String]()
  }

  /// Random histories from the convergence generators; then, for every occurrence on the days around the open day and every action, and "No spend" on
  /// the days around it, the command is issued on a copy of the replayed state: whatever the board offers replay applies, and whatever it blocks replay does not, but for the client's own policy.
  @Test func shouldOfferExactlyTheActionsReplayTakes() async throws {
    var tally = Tally()
    try await forAll(iterations: 12) { generator in
      let device = try ReadsDevice()
      let created = Int64(ReplaySamples.firstDay - 1) * ReplaySamples.millisPerDay + 6 * 3_600_000
      var history = try zip(ReplaySamples.quests, try ReplaySamples.schedules()).map { quest, schedule in
        try ReplaySamples.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
      }
      let days = generator.int(in: 1...6)
      for index in 0..<days {
        let day = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + index))
        let minutes = (0..<generator.int(in: 0...4)).map { _ in generator.int(in: 360...1_380) }.sorted()
        for minute in minutes {
          let instant = Int64(day.daysSinceEpoch) * ReplaySamples.millisPerDay + Int64(minute) * 60_000
          history.append(try ReplaySamples.command(try ReplaySamples.randomBody(on: day, using: &generator), at: instant, offset: 0, using: &generator))
        }
      }
      try await device.append(history)
      let openDay = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + days - 1))
      try await device.walk(to: openDay, minute: 1_400)
      let base = Replay.run(try await device.store.read { transaction in try Replay.commands(in: transaction) })
      let instant = Int64(openDay.daysSinceEpoch) * ReplaySamples.millisPerDay + 1_420 * 60_000
      var number = 0

      func check(_ availability: ActionAvailability, _ body: () throws -> MemoirCommandBody, _ what: String, rulesetVersion: Int = Ruleset.v1.version) throws {
        if case .unavailable(let block) = availability, Self.isPolicy(block) { return }
        number += 1
        let command = try MemoirCommand(
          id: MemoirStoreFixture.commandID(900_000 + number), body: try body(), instantMillis: instant, utcOffsetMinutes: 0, issuedOn: openDay,
          rulesetVersion: rulesetVersion)
        let outcome = try Replay.extend(base, with: [try ReplayFixture.entry(command, wall: 4_000_000_000_000)]).outcomes[command.id]
        let offered = availability.isPossible(at: instant)
        if offered { tally.offered += 1 } else { tally.blocked += 1 }
        if offered != (outcome == .applied) { tally.mismatches.append("\(what): \(availability) but \(String(describing: outcome))") }
      }

      for date in [openDay.movedBy(days: -1), openDay, openDay.movedBy(days: 1)] {
        let board = try await device.board(date)
        for occurrence in board.occurrences {
          let at = occurrence.occurrence
          let actions = occurrence.actions
          let label = "\(at.quest) on \(date) (open \(openDay))"
          var accept = false
          if case .needsConfirmation(.rescheduleBecomesPostpone) = actions.reschedule { accept = true }
          try check(actions.complete, { .questComplete(at) }, "complete \(label)")
          try check(actions.partial, { .questPartial(at) }, "partial \(label)")
          try check(actions.skip, { .questSkip(QuestBreak(occurrence: at, reasonTag: .other)) }, "skip \(label)")
          try check(actions.postpone, { .questPostpone(QuestBreak(occurrence: at)) }, "postpone \(label)")
          try check(actions.reschedule, { .questReschedule(try QuestReschedule(occurrence: at, toMinute: 700, acceptBeyondCap: accept)) }, "reschedule \(label)")
          try check(actions.attachReason, { .questAttachReason(try QuestReason(occurrence: at, reasonTag: .travel, hasNote: false)) }, "reason \(label)")
          try check(actions.deleteLog, { .questDeleteLog(at) }, "delete \(label)")
        }
        guard board.relation == .today else { continue }
        let lockable = board.occurrences.filter { $0.isScheduled && $0.quest.isActive }.map(\.quest.id)
        try check(board.lock.lock, { .planSetLock(try PlanLock(locking: lockable)) }, "lock \(date)")
        try check(board.lock.unlock, { .planSetLock(.unlocked) }, "unlock \(date)")
        if let recovery = board.recovery { try check(recovery.complete, { .recoveryComplete(RecoveryCompletion()) }, "recovery \(date)") }
      }

      let money = try await device.board(openDay).money
      #expect(money.logging.allSatisfy { $0.noSpend == money.noSpend(on: $0.date) })
      for offset in -4...1 {
        let date = openDay.movedBy(days: offset)
        try check(money.noSpend(on: date), { .moneyNoSpend(NoSpendDay(date: date)) }, "no spend on \(date) (open \(openDay))", rulesetVersion: Ruleset.current.version)
      }
    }
    #expect(tally.mismatches.isEmpty, "\(tally.mismatches.prefix(5).joined(separator: "\n"))")
    #expect(tally.offered > 50 && tally.blocked > 50, "the histories exercised both sides: \(tally.offered) offered, \(tally.blocked) blocked")
  }
}

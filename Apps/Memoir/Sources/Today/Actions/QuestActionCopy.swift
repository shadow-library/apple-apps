import Foundation
import MemoirCore

/// The reference's words for quest actions and their states (`lib/data/labels.ts`, `quest-presenters.ts`, `quest-actions.tsx`, `command-errors.ts`).
enum QuestActionCopy {
  static func name(_ quest: QuestSnapshot) -> String {
    quest.name ?? String(localized: "Unnamed quest", table: "Today")
  }

  static func strictness(_ strictness: Strictness) -> String {
    switch strictness {
    case .anchor: String(localized: "Anchor", table: "Today")
    case .routine: String(localized: "Routine", table: "Today")
    case .goal: String(localized: "Goal", table: "Today")
    case .recovery: String(localized: "Recovery", table: "Today")
    case .optional: String(localized: "Optional", table: "Today")
    }
  }

  static func strictnessRule(_ strictness: Strictness) -> String {
    switch strictness {
    case .anchor:
      String(localized: "A fixed time, with thirty minutes of grace. A break spends HP when the day closes, unless your intensity is gentle.", table: "Today")
    case .routine:
      String(localized: "A window the length of the quest. A break spends HP when the day closes, unless your intensity is gentle.", table: "Today")
    case .goal: String(localized: "Judged on the day, not the hour. A break never costs HP.", table: "Today")
    case .recovery: String(localized: "Offered the day after a miss. It never costs HP, keeps no streak and can never trigger another.", table: "Today")
    case .optional: String(localized: "Reward only. A break never costs HP, and ends a streak only if you keep one for it.", table: "Today")
    }
  }

  static func stat(_ stat: StatAffinity) -> String {
    switch stat {
    case .discipline: String(localized: "Discipline", table: "Today")
    case .body: String(localized: "Body", table: "Today")
    case .wealth: String(localized: "Wealth", table: "Today")
    case .mind: String(localized: "Mind", table: "Today")
    }
  }

  static func state(_ state: QuestLogState) -> String {
    switch state {
    case .completed: String(localized: "Kept", table: "Today")
    case .partial: String(localized: "Partial", table: "Today")
    case .late: String(localized: "Late", table: "Today")
    case .skipped: String(localized: "Skipped", table: "Today")
    case .missed: String(localized: "Missed", table: "Today")
    case .postponed: String(localized: "Postponed", table: "Today")
    case .rescheduled: String(localized: "Moved", table: "Today")
    case .recovery: String(localized: "Recovery", table: "Today")
    }
  }

  static func reason(_ tag: ReasonTag) -> String {
    switch tag {
    case .forgot: String(localized: "forgot", table: "Today")
    case .tooTired: String(localized: "too tired", table: "Today")
    case .taskTooBig: String(localized: "task too big", table: "Today")
    case .scheduleConflict: String(localized: "schedule conflict", table: "Today")
    case .avoidedIt: String(localized: "avoided it", table: "Today")
    case .emotionalResistance: String(localized: "emotional resistance", table: "Today")
    case .health: String(localized: "health", table: "Today")
    case .travel: String(localized: "travel", table: "Today")
    case .familySocial: String(localized: "family or social", table: "Today")
    case .workEmergency: String(localized: "work emergency", table: "Today")
    case .notImportantAnymore: String(localized: "not important anymore", table: "Today")
    case .poorlyPlanned: String(localized: "poorly planned", table: "Today")
    case .other: String(localized: "other", table: "Today")
    }
  }

  static func label(_ kind: QuestActionKind) -> String {
    switch kind {
    case .complete: String(localized: "Complete", table: "Today")
    case .partial: String(localized: "Partial", table: "Today")
    case .postpone: String(localized: "Postpone to tomorrow", table: "Today")
    case .reschedule: String(localized: "Reschedule to another time", table: "Today")
    case .skip: String(localized: "Skip", table: "Today")
    case .attachReason: String(localized: "Add a reason", table: "Today")
    case .undo: String(localized: "Undo", table: "Today")
    }
  }

  static func streak(days: Int, unit: StreakUnit) -> String {
    switch unit {
    case .days: String(localized: "\(days)-day streak", table: "Today")
    case .occurrences: String(localized: "\(days)-occurrence streak", table: "Today")
    }
  }

  static func shields(_ count: Int) -> String {
    String(localized: "\(count) shields", table: "Today")
  }

  /// `breakStreakNote` (`quest-presenters.ts:186-190`), from what replay would do to the streak.
  static func streakNote(_ cost: BreakCost) -> String {
    switch cost.streak {
    case .untracked: String(localized: "Doesn’t touch a streak — this quest doesn’t keep one.", table: "Today")
    case .bridgedByShield: String(localized: "A held shield bridges the break — the streak continues, but the shield is spent.", table: "Today")
    case .ends: String(localized: "Breaks the streak.", table: "Today")
    }
  }

  /// `breakCostNote` (`quest-presenters.ts:197-202`), from the HP the day's close would charge.
  static func costNote(_ occurrence: BoardOccurrence) -> String {
    let hp = occurrence.breakCost.hp
    if hp > 0 { return String(localized: "Spends \(hp) HP when the day closes.", table: "Today") }
    let costing: Set<Strictness> = [.anchor, .routine]
    guard costing.contains(occurrence.quest.strictness), occurrence.intensityMode == .lowIntensity else {
      return String(localized: "No HP is spent.", table: "Today")
    }
    return String(localized: "No HP is spent — gentle intensity.", table: "Today")
  }

  static var lockNote: String {
    String(localized: "Postponing breaks today’s locked plan, so its lock bonus stops for every quest in it.", table: "Today")
  }

  static var skipReasonNote: String {
    String(localized: "A reason is optional, and any you give is only ever shown to you.", table: "Today")
  }

  static func rule(_ kind: QuestActionKind, for occurrence: BoardOccurrence) -> String {
    let notes = [streakNote(occurrence.breakCost), costNote(occurrence)]
    switch kind {
    case .complete:
      return [strictnessRule(occurrence.quest.strictness), String(localized: "\(stat(occurrence.quest.statAffinity)) gains a point.", table: "Today")]
        .joined(separator: " ")
    case .partial:
      return String(localized: "Keeps the streak and grants XP for what you did. A reason is optional.", table: "Today")
    case .postpone:
      return (notes + (occurrence.actions.postpone == .needsConfirmation(.breaksPlanLock) ? [lockNote] : [])).joined(separator: " ")
    case .reschedule:
      if case .needsConfirmation(.rescheduleBecomesPostpone) = occurrence.actions.reschedule {
        return String(localized: "The reschedule cap is reached, so moving this occurrence is recorded as a postpone.", table: "Today")
      }
      return String(localized: "Moves only this occurrence’s time today. The streak is untouched while the move is inside the cap.", table: "Today")
    case .skip:
      return (notes + [skipReasonNote]).joined(separator: " ")
    case .attachReason:
      return String(localized: "Adds a reason to what was recorded. It is only ever shown to you.", table: "Today")
    case .undo:
      return ""
    }
  }

  /// Why the action is not offered, in the reference's words where it has them.
  static func unavailable(_ reason: QuestActionUnavailable, for kind: QuestActionKind) -> String? {
    switch reason {
    case .blocked(let block): blocked(block, for: kind)
    case .editWindowClosed: String(localized: "Entries older than 7 days can’t be changed.", table: "Today")
    case .gone: String(localized: "That quest isn’t in your plan any more.", table: "Today")
    case .inProgress: String(localized: "The last change to this quest is still being saved.", table: "Today")
    case .notUndoable: String(localized: "It changed since, so it can’t be undone any more.", table: "Today")
    case .timePassed: String(localized: "Pick a time that hasn’t passed yet.", table: "Today")
    case .needsConfirmation: nil
    }
  }

  static func blocked(_ block: ActionBlock, for kind: QuestActionKind) -> String {
    switch block {
    case .questInactive: String(localized: "That quest isn’t in your plan any more.", table: "Today")
    case .notScheduled: String(localized: "That quest isn’t scheduled on that day.", table: "Today")
    case .notYetBegun: String(localized: "That day hasn’t started yet.", table: "Today")
    case .dayPassed, .notAccountDay: String(localized: "That day is already closed.", table: "Today")
    case .alreadyRecorded(let state): alreadyRecorded(state)
    case .alreadyRescheduled: String(localized: "Already moved once today.", table: "Today")
    case .notAllowedFor:
      kind == .reschedule
        ? String(localized: "Reschedule doesn’t apply to this strictness.", table: "Today")
        : String(localized: "Postpone does not apply to this strictness.", table: "Today")
    case .rescheduleCapReached: String(localized: "It has already been moved twice this week.", table: "Today")
    case .nothingRecorded: String(localized: "There’s nothing logged for that quest to change.", table: "Today")
    case .nothingToLock: String(localized: "Nothing is scheduled today to lock.", table: "Today")
    case .notLocked: String(localized: "Today’s plan isn’t locked.", table: "Today")
    case .recoveryClosed: String(localized: "There’s no recovery quest waiting today.", table: "Today")
    case .lockedInTodaysPlan: String(localized: "This quest is in today’s locked plan, so its schedule stays as planned.", table: "Today")
    }
  }

  static func alreadyRecorded(_ state: QuestLogState) -> String {
    switch state {
    case .completed: String(localized: "Already recorded as kept.", table: "Today")
    case .partial: String(localized: "Already recorded as partial.", table: "Today")
    case .late: String(localized: "Already recorded as late.", table: "Today")
    case .skipped: String(localized: "Already recorded as skipped.", table: "Today")
    case .missed: String(localized: "Already recorded as missed.", table: "Today")
    case .postponed: String(localized: "Already recorded as postponed.", table: "Today")
    case .rescheduled: String(localized: "Already recorded as moved.", table: "Today")
    case .recovery: String(localized: "Already recorded as recovery.", table: "Today")
    }
  }

  /// The reason shown in place of an action's rule, nil while it can be taken (a confirmation is asked for in its own sheet).
  static func disabledReason(_ kind: QuestActionKind, for occurrence: BoardOccurrence, at instantMillis: Int64) -> String? {
    switch kind.availability(in: occurrence.actions) {
    case .available, .needsConfirmation: nil
    case .availableUntil(let millis): instantMillis <= millis ? nil : unavailable(.editWindowClosed, for: kind)
    case .unavailable(let block): blocked(block, for: kind)
    }
  }

  /// `messageFor` (`fixture-provider.ts:731-737`) with the break notes `quest-actions.tsx` adds to a skip or postpone.
  static func success(_ request: QuestActionRequest, for occurrence: BoardOccurrence) -> String {
    let name = name(occurrence.quest)
    let notes = [streakNote(occurrence.breakCost), costNote(occurrence)]
    switch request {
    case .complete: return String(localized: "\(name) completed.", table: "Today")
    case .partial: return String(localized: "\(name) recorded as partial, and the streak holds.", table: "Today")
    case .skip(_, let reason):
      let skipped =
        reason.isEmpty
        ? String(localized: "\(name) skipped.", table: "Today") : String(localized: "\(name) skipped. The reason is only ever shown to you.", table: "Today")
      return ([skipped] + notes).joined(separator: " ")
    case .postpone: return ([String(localized: "\(name) moved to tomorrow.", table: "Today")] + notes).joined(separator: " ")
    case .reschedule(_, let minute, let acceptBeyondCap):
      if acceptBeyondCap, case .needsConfirmation = occurrence.actions.reschedule {
        return ([String(localized: "\(name) moved to tomorrow.", table: "Today")] + notes).joined(separator: " ")
      }
      return String(localized: "\(name) moved to \(TodayFormat.time(minuteOfDay: minute)). The streak is untouched.", table: "Today")
    case .attachReason: return String(localized: "Reason saved. It is only ever shown to you.", table: "Today")
    case .undo: return String(localized: "\(name) is open again.", table: "Today")
    }
  }

  /// `couldNot` (`command-feedback.ts:93-96`), one sentence per action so each reads naturally once translated.
  static func failure(_ kind: QuestActionKind, name: String, message: String) -> String {
    switch kind {
    case .complete: String(localized: "Couldn’t complete ‘\(name)’: \(message)", table: "Today")
    case .partial: String(localized: "Couldn’t save the partial for ‘\(name)’: \(message)", table: "Today")
    case .postpone: String(localized: "Couldn’t postpone ‘\(name)’: \(message)", table: "Today")
    case .reschedule: String(localized: "Couldn’t move ‘\(name)’: \(message)", table: "Today")
    case .skip: String(localized: "Couldn’t skip ‘\(name)’: \(message)", table: "Today")
    case .attachReason: String(localized: "Couldn’t save the reason for ‘\(name)’: \(message)", table: "Today")
    case .undo: String(localized: "Couldn’t undo ‘\(name)’: \(message)", table: "Today")
    }
  }

  static var unsaved: String { String(localized: "Your last change to this quest wasn’t saved.", table: "Today") }
}

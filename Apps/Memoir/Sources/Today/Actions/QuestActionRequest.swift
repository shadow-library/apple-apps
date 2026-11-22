import Foundation
import MemoirCore

/// The actions an occurrence offers, in the order the reference lists them (`quest-actions.tsx`), plus attaching a reason to a recorded outcome.
nonisolated enum QuestActionKind: String, CaseIterable, Hashable, Sendable {
  case complete
  case partial
  case postpone
  case reschedule
  case skip
  case attachReason
  case undo

  static let menu: [QuestActionKind] = [.complete, .partial, .postpone, .reschedule, .skip, .attachReason]

  func availability(in actions: OccurrenceActions) -> ActionAvailability {
    switch self {
    case .complete: actions.complete
    case .partial: actions.partial
    case .postpone: actions.postpone
    case .reschedule: actions.reschedule
    case .skip: actions.skip
    case .attachReason: actions.attachReason
    case .undo: actions.deleteLog
    }
  }
}

/// A reason tag and a note, either of which may be left out; a blank note is no note.
nonisolated struct QuestActionReason: Hashable, Sendable {
  static let none = QuestActionReason(tag: nil, note: "")
  /// `ContentRules.reasonNoteMaximumLength` in UTF-16 units, which the core keeps internal.
  static let noteLimit = 120

  let tag: ReasonTag?
  let note: String?

  init(tag: ReasonTag?, note: String) {
    self.tag = tag
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    self.note = trimmed.isEmpty ? nil : trimmed
  }

  var isEmpty: Bool { tag == nil && note == nil }
  var isNoteTooLong: Bool { (note?.utf16.count ?? 0) > Self.noteLimit }
}

nonisolated struct QuestActionCommand: Hashable, Sendable {
  let body: MemoirCommandBody
  let text: String?
}

nonisolated enum QuestActionRequest: Hashable, Sendable {
  case complete(Occurrence)
  case partial(Occurrence, QuestActionReason)
  case skip(Occurrence, QuestActionReason)
  case postpone(Occurrence, breakingLock: Bool)
  case reschedule(Occurrence, toMinute: Int, acceptBeyondCap: Bool)
  case attachReason(Occurrence, QuestActionReason)
  case undo(Occurrence)

  var occurrence: Occurrence {
    switch self {
    case .complete(let occurrence), .partial(let occurrence, _), .skip(let occurrence, _), .postpone(let occurrence, _), .reschedule(let occurrence, _, _),
      .attachReason(let occurrence, _), .undo(let occurrence):
      occurrence
    }
  }

  var kind: QuestActionKind {
    switch self {
    case .complete: .complete
    case .partial: .partial
    case .skip: .skip
    case .postpone: .postpone
    case .reschedule: .reschedule
    case .attachReason: .attachReason
    case .undo: .undo
    }
  }

  var reason: QuestActionReason {
    switch self {
    case .partial(_, let reason), .skip(_, let reason), .attachReason(_, let reason): reason
    case .complete, .postpone, .reschedule, .undo: .none
    }
  }

  func confirms(_ confirmation: ActionConfirmation) -> Bool {
    switch (self, confirmation) {
    case (.postpone(_, let breakingLock), .breaksPlanLock): breakingLock
    case (.reschedule(_, _, let acceptBeyondCap), .rescheduleBecomesPostpone): acceptBeyondCap
    default: false
    }
  }

  /// `quest.partial` carries no reason (the reference's server drops the one its client sends), so a reason given with a partial is attached by a
  /// `quest.attachReason` in the same write.
  func commands() throws(CommandRefusal) -> [QuestActionCommand] {
    switch self {
    case .complete(let occurrence):
      return [QuestActionCommand(body: .questComplete(occurrence), text: nil)]
    case .partial(let occurrence, let reason):
      let partial = QuestActionCommand(body: .questPartial(occurrence), text: nil)
      guard !reason.isEmpty else { return [partial] }
      return [partial, try Self.attaching(reason, to: occurrence)]
    case .skip(let occurrence, let reason):
      return [QuestActionCommand(body: .questSkip(QuestBreak(occurrence: occurrence, reasonTag: reason.tag, hasNote: reason.note != nil)), text: reason.note)]
    case .postpone(let occurrence, _):
      return [QuestActionCommand(body: .questPostpone(QuestBreak(occurrence: occurrence)), text: nil)]
    case .reschedule(let occurrence, let toMinute, let acceptBeyondCap):
      let reschedule = try QuestReschedule(occurrence: occurrence, toMinute: toMinute, acceptBeyondCap: acceptBeyondCap)
      return [QuestActionCommand(body: .questReschedule(reschedule), text: nil)]
    case .attachReason(let occurrence, let reason):
      return [try Self.attaching(reason, to: occurrence)]
    case .undo(let occurrence):
      return [QuestActionCommand(body: .questDeleteLog(occurrence), text: nil)]
    }
  }

  private static func attaching(_ reason: QuestActionReason, to occurrence: Occurrence) throws(CommandRefusal) -> QuestActionCommand {
    QuestActionCommand(
      body: .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: reason.tag, hasNote: reason.note != nil)), text: reason.note)
  }

  /// `canUndo` (`quest-actions.tsx:54-61`): `quest.deleteLog` removes the log but reverts nothing else (XP stays granted, a broken streak or spent shield
  /// stays), so only a bare skip or postpone of an open occurrence with nothing to lose is offered back.
  func offersUndo(on occurrence: BoardOccurrence) -> Bool {
    guard occurrence.status == .open else { return false }
    switch self {
    case .skip(_, let reason): guard reason.isEmpty else { return false }
    case .postpone: guard !occurrence.locked else { return false }
    case .complete, .partial, .reschedule, .attachReason, .undo: return false
    }
    return Self.hasNothingToLose(occurrence)
  }

  /// Undo deletes the log as it stands now, which may no longer be the skip or postpone it was offered for: a reason attached since, or an outcome
  /// synced from another device that replaced it, would be deleted with its reward kept and granted again. So the row must still be a bare break,
  /// and a postpone must not be one that broke the day's lock.
  func isUndoable(_ occurrence: BoardOccurrence, lock: DayLockSummary?) -> Bool {
    guard case .undo = self, let log = occurrence.log else { return false }
    switch log.state {
    case .skipped: break
    case .postponed:
      guard !occurrence.locked, !(lock.map { $0.state != .none && $0.quests.contains(occurrence.quest.id) } ?? false) else { return false }
    case .completed, .partial, .late, .missed, .rescheduled, .recovery: return false
    }
    guard log.reasonTag == nil, log.reasonNote == nil, log.reflection == nil, log.xpAwarded == 0, log.coinsAwarded == 0 else { return false }
    return Self.hasNothingToLose(occurrence)
  }

  private static func hasNothingToLose(_ occurrence: BoardOccurrence) -> Bool {
    occurrence.quest.strictness == .recovery || (occurrence.streak.currentDays == 0 && occurrence.streak.shields == 0)
  }
}

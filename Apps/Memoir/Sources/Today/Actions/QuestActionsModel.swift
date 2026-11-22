import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// Why an action was not issued.
enum QuestActionUnavailable: Equatable {
  case blocked(ActionBlock)
  case editWindowClosed
  case needsConfirmation(ActionConfirmation)
  /// The occurrence is no longer on the board the action was asked from.
  case gone
  case inProgress
  /// The row no longer shows the bare skip or postpone that Undo was offered for.
  case notUndoable
  /// A reschedule of today's occurrence to a minute the account's clock has already passed.
  case timePassed
}

/// Where the account stands when an action is asked for: its day and minute on the account's clock, and that day's plan lock.
struct QuestActionMoment: Equatable {
  let date: LocalDate
  let minuteOfDay: Int
  let lock: DayLockSummary?
}

enum QuestActionOutcome: Equatable {
  case done(offersUndo: Bool)
  case unavailable(QuestActionUnavailable)
  case failed(PresentedError)
  case cancelled
}

/// Issues an occurrence's actions through the screen's writer, only those the board's `OccurrenceActions` allow at the trusted now, each as one write.
@MainActor
@Observable
final class QuestActionsModel {
  private(set) var busy: Set<Occurrence> = []
  private(set) var unsaved: Set<Occurrence> = []
  private(set) var isCompletingRecovery = false
  private(set) var recoveryFailure: PresentedError?
  private let writer: MemoirWriter

  init(writer: MemoirWriter) {
    self.writer = writer
  }

  /// `occurrence` is the board's latest row for the request's occurrence, nil when the board no longer lists it.
  func perform(_ request: QuestActionRequest, on occurrence: BoardOccurrence?, at moment: QuestActionMoment?) async -> QuestActionOutcome {
    let id = request.occurrence
    guard let occurrence, occurrence.id == id else { return .unavailable(.gone) }
    guard !busy.contains(id) else { return .unavailable(.inProgress) }
    let refusal = Self.refusal(of: request, on: occurrence, at: MemoirClock.millis(writer.clock.now()), moment: moment)
    if let refusal { return .unavailable(refusal) }
    let offersUndo = request.offersUndo(on: occurrence)
    busy.insert(id)
    defer { busy.remove(id) }
    do throws(MemoirWriteError) {
      let commands: [QuestActionCommand]
      do throws(CommandRefusal) {
        commands = try request.commands()
      } catch {
        throw .command(.refused(error))
      }
      try await writer.write { issuer, transaction in
        for command in commands { try issuer.issue(command.body, text: command.text, in: &transaction) }
      }
    } catch {
      guard let presented = WritingErrors.presented(error) else { return .cancelled }
      unsaved.insert(id)
      return .failed(presented)
    }
    unsaved.remove(id)
    return .done(offersUndo: offersUndo)
  }

  func completeRecovery(_ offer: RecoveryOffer?, reflection: String) async -> QuestActionOutcome {
    guard let offer else { return .unavailable(.gone) }
    if case .unavailable(let block) = offer.complete { return .unavailable(.blocked(block)) }
    guard !isCompletingRecovery else { return .unavailable(.inProgress) }
    let trimmed = reflection.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = trimmed.isEmpty ? nil : trimmed
    isCompletingRecovery = true
    defer { isCompletingRecovery = false }
    do throws(MemoirWriteError) {
      try await writer.issue(.recoveryComplete(RecoveryCompletion(hasReflection: text != nil)), text: text)
    } catch {
      guard let presented = WritingErrors.presented(error) else { return .cancelled }
      recoveryFailure = presented
      return .failed(presented)
    }
    recoveryFailure = nil
    return .done(offersUndo: false)
  }

  /// The reason a reason replaces, to start the form from: `quest.attachReason` writes both the tag and the note.
  func existingReason(of occurrence: BoardOccurrence) async -> QuestActionReason {
    guard let log = occurrence.log else { return .none }
    guard let command = log.reasonNote else { return QuestActionReason(tag: log.reasonTag, note: "") }
    let note = try? await writer.stores.main.read { transaction in try CommandNoteRecord.read(id: command, in: transaction).entry?.record.text }
    return QuestActionReason(tag: log.reasonTag, note: note.flatMap(\.self) ?? "")
  }

  /// Availability first, as replay checks it; then a time already passed, before any confirmation is asked for; then what Undo may still delete.
  static func refusal(
    of request: QuestActionRequest, on occurrence: BoardOccurrence, at instantMillis: Int64, moment: QuestActionMoment?
  ) -> QuestActionUnavailable? {
    let availability = request.kind.availability(in: occurrence.actions)
    switch availability {
    case .unavailable(let block): return .blocked(block)
    case .availableUntil(let millis) where instantMillis > millis: return .editWindowClosed
    case .available, .availableUntil, .needsConfirmation: break
    }
    if case .reschedule(_, let minute, _) = request, let moment, occurrence.occurrence.date == moment.date, minute < moment.minuteOfDay { return .timePassed }
    if case .undo = request, !request.isUndoable(occurrence, lock: moment?.lock) { return .notUndoable }
    if case .needsConfirmation(let confirmation) = availability, !request.confirms(confirmation) { return .needsConfirmation(confirmation) }
    return nil
  }
}

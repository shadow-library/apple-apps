import Foundation
import ShadowCore
import ShadowStore

public enum CommandIssueError: ShadowError {
  case refused(CommandRefusal)
  case clock(CalendarError)
  case command(MemoirCommandError)
  case record(MemoirRecordError)
  case finance(FinanceError)

  public var code: String {
    switch self {
    case .refused(let refusal): refusal.code
    case .clock(let error): error.code
    case .command(let error): error.code
    case .record(let error): error.code
    case .finance(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .refused(let refusal): refusal.errorDescription
    case .clock(let error): error.errorDescription
    case .command(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .finance(let error): error.errorDescription
    }
  }
}

/// Turns a typed body into an appended `mm_command`: a UUIDv7 id, the device's instant, the UTC offset in force and the zone's date at it
/// (`IssueClock.stamp`), and `Ruleset.current`'s version.
///
/// `issuedOn` is the zone's date, never the account's open day: after a backward zone change the open day can run ahead of it
/// (`accountToday`, `rules/time.ts:157-161`), but the open day is derived state, so replay takes `max(issuedOn, open day)` itself.
/// The clock should be built on the account's time zone in force, which replay has promoted, not necessarily the device's.
public struct CommandIssuer: Sendable {
  public let clock: IssueClock
  private let wallClock: @Sendable () -> Date

  public init(clock: IssueClock, wallClock: @escaping @Sendable () -> Date = { Date() }) {
    self.clock = clock
    self.wallClock = wallClock
  }

  public func command(_ body: MemoirCommandBody) throws(CommandIssueError) -> MemoirCommand {
    let now = wallClock()
    guard let instant = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) else { throw .clock(.dateOutOfRange) }
    let stamp: IssueStamp
    do throws(CalendarError) {
      stamp = try clock.stamp(at: instant)
    } catch {
      throw .clock(error)
    }
    do throws(MemoirCommandError) {
      return try MemoirCommand(
        id: UUID.v7(at: now), body: body, instantMillis: stamp.instantMillis, utcOffsetMinutes: stamp.utcOffsetMinutes, issuedOn: stamp.issuedOn,
        rulesetVersion: Ruleset.current.version)
    } catch {
      if case .body(let refusal) = error { throw .refused(refusal) }
      throw .command(error)
    }
  }

  /// Appends the command and, when its body has a text slot, the text as its `CommandNoteRecord`, in the caller's transaction. Content records the
  /// command names are written by the caller through their typed records; a health-class one goes to the restricted store's own transaction.
  @discardableResult
  public func issue(_ body: MemoirCommandBody, text: String? = nil, in transaction: inout WriteTransaction) throws(CommandIssueError) -> MemoirCommand {
    do throws(CommandRefusal) {
      try Self.validate(text: text, for: body)
    } catch {
      throw .refused(error)
    }
    let command = try command(body)
    var note: CommandNoteRecord?
    if let text {
      do throws(MemoirCommandError) {
        note = try CommandNoteRecord(command: command.id, text: text)
      } catch {
        throw .command(error)
      }
    }
    do throws(MemoirRecordError) {
      try command.append(in: &transaction)
      try note?.append(in: &transaction)
    } catch {
      throw .record(error)
    }
    return command
  }

  /// Runs the reference's checks on the record the command names before issuing it. The caller still writes the record through its typed record write,
  /// in this transaction for a main-store record and in the restricted store's own for a health-class one.
  @discardableResult
  public func issue(
    _ body: MemoirCommandBody, text: String? = nil, content: some CommandContent, in transaction: inout WriteTransaction
  ) throws(CommandIssueError) -> MemoirCommand {
    do throws(CommandRefusal) {
      try content.validate()
    } catch {
      throw .refused(error)
    }
    return try issue(body, text: text, in: &transaction)
  }

  /// Confirms a subscription cycle in one write: finance writes the cycle's expense under its derived id, logged at the command's instant, and the
  /// command is appended after it. A refusal from either throws, and the caller's write then rolls both back.
  @discardableResult
  public func confirmCycle(_ confirmation: CycleConfirmation, in transaction: inout WriteTransaction) throws(CommandIssueError) -> (
    command: MemoirCommand, expense: ExpenseRecord?
  ) {
    let command = try command(.subscriptionConfirmCycle(confirmation))
    let expense: ExpenseRecord?
    do throws(FinanceError) {
      expense = try SubscriptionCycles.confirm(confirmation, loggedAtMillis: command.instantMillis, in: &transaction)
    } catch {
      throw .finance(error)
    }
    do throws(MemoirRecordError) {
      try command.append(in: &transaction)
    } catch {
      throw .record(error)
    }
    return (command, expense)
  }

  /// The text must come exactly when the body says one is attached: a reason note of 1 to 120 UTF-16 units, or a non-empty reflection.
  public static func validate(text: String?, for body: MemoirCommandBody) throws(CommandRefusal) {
    switch (body.textSlot, text) {
    case (nil, nil): return
    case (nil, .some): throw .textUnexpected
    case (let slot?, nil): throw .textRequired(field: slot.rawValue)
    case (.reasonNote?, let text?): try ContentRules.reasonNote(text)
    case (.reflection?, let text?): try ContentRules.reflection(text)
    }
  }
}

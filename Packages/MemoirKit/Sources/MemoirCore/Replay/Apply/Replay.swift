import Foundation
import ShadowCore
import ShadowStore

/// One `mm_command` item as replay reads it, placed by the kernel's clock on the appended item.
public enum ReplayCommand: Sendable, Equatable {
  case readable(AppendedEntry<MemoirCommand>)
  /// An item this app cannot read as a command at all; replay halts on it.
  case unreadable(ref: EntityRef, clock: HLCTimestamp)

  public var ref: EntityRef {
    switch self {
    case .readable(let entry): entry.record.ref
    case .unreadable(let ref, _): ref
    }
  }

  public var clock: HLCTimestamp {
    switch self {
    case .readable(let entry): entry.clock
    case .unreadable(_, let clock): clock
    }
  }
}

/// Replay derives hero state from the command log: commands in clock order, each applied under its own ruleset version to the state the ones before
/// it left. It reads only what commands recorded (instants, offsets, `issuedOn`) and never the device's clock or zone data.
public enum Replay {
  /// By the clock on the appended item, then by id, so every device orders the same set the same way.
  public static func ordered(_ commands: [ReplayCommand]) -> [ReplayCommand] {
    commands.sorted { first, second in
      guard first.clock == second.clock else { return first.clock < second.clock }
      return first.ref < second.ref
    }
  }

  /// Every command item in the store, readable or not, in replay order.
  public static func commands<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(StoreError) -> [ReplayCommand] {
    var commands = [ReplayCommand]()
    for (ref, state) in try source.states(ofKind: MemoirKind.command.entityKind, scope: .vault) {
      guard case .appended(let appended) = state else { continue }
      switch MemoirCommand.reading(state, of: ref) {
      case .absent: continue
      case .readable(let entry): commands.append(.readable(entry))
      case .unreadable: commands.append(.unreadable(ref: ref, clock: appended.clock))
      }
    }
    return ordered(commands)
  }

  public static func run(_ commands: [ReplayCommand], from initial: ReplayState = .initial) -> ReplayState {
    ordered(commands).reduce(into: initial) { state, command in apply(command, to: &state) }
  }

  /// Applies one command. A halted replay takes nothing more, and a command already taken in is not taken again.
  public static func apply(_ command: ReplayCommand, to state: inout ReplayState) {
    guard state.halt == nil else { return }
    guard case .readable(let entry) = command else {
      state.halt = .unreadableCommand(command.ref)
      return
    }
    let stored = entry.record
    guard state.outcomes[stored.id] == nil else { return }
    let body: MemoirCommandBody
    do throws(CommandRefusal) {
      body = try MemoirCommandBody(stored)
    } catch {
      if case .unknownType(let type) = error {
        state.halt = .unknownCommandType(command: stored.id, type: type)
        return
      }
      state.halt = .unreadableCommand(stored.ref)
      return
    }
    guard let ruleset = Ruleset.version(stored.rulesetVersion) else {
      state.halt = .rulesetUnavailable(command: stored.id, version: stored.rulesetVersion)
      return
    }

    let context = ApplyContext(command: stored, ruleset: ruleset, accountDay: state.accountDay(issuedOn: stored.issuedOn), order: state.commandCount)
    let outcome: ReplayOutcome
    do throws(ReplayRefusal) {
      outcome = try state.apply(body, in: context)
    } catch {
      outcome = .refused(error)
      if case .notEnoughCoins(let balance, let required) = error, case .cosmeticPurchase(let cosmetic) = body {
        state.notices.append(.purchaseWithdrawn(command: stored.id, cosmetic: cosmetic, balance: balance, price: required))
      }
    }
    state.outcomes[stored.id] = outcome
    state.commandCount += 1
    state.latestIssuedOn = max(stored.issuedOn, state.latestIssuedOn ?? stored.issuedOn)
    state.highestRulesetVersion = max(ruleset.version, state.highestRulesetVersion ?? ruleset.version)
  }
}

/// What one command's handler reads besides the state: the command's recorded fields, its ruleset and the account's day at it.
struct ApplyContext: Sendable {
  static let millisPerMinute: Int64 = 60_000
  static let millisPerDay: Int64 = 86_400_000
  /// A device clock a little ahead stamps tomorrow in the last minutes of today, so an occurrence counts as begun that far ahead.
  static let midnightSkewMillis: Int64 = 5 * millisPerMinute

  let command: MemoirCommand
  let ruleset: Ruleset
  let accountDay: LocalDate
  let order: Int

  var id: UUID { command.id }
  var instant: Int64 { command.instantMillis }
  var issuedOn: LocalDate { command.issuedOn }

  var minuteOfDay: Int {
    let local = instant + Int64(command.utcOffsetMinutes) * Self.millisPerMinute
    let intoDay = ((local % Self.millisPerDay) + Self.millisPerDay) % Self.millisPerDay
    return Int(intoDay / Self.millisPerMinute)
  }

  /// The latest day an occurrence may be for and still have begun: the zone's date five minutes on, or the open day if that is later.
  func latestBegunDay(openDay: LocalDate?) -> LocalDate {
    let (ahead, overflow) = instant.addingReportingOverflow(Self.midnightSkewMillis)
    let skewed = overflow ? issuedOn : ((try? MemoirCommand.localDate(instantMillis: ahead, utcOffsetMinutes: command.utcOffsetMinutes)) ?? issuedOn)
    return max(skewed, openDay ?? skewed)
  }
}

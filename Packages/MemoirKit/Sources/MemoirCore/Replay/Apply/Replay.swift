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

  public var position: ReplayPosition { ReplayPosition(clock: clock, ref: ref) }
}

/// A command's place in replay order: the clock on the appended item, then its ref.
public struct ReplayPosition: Sendable, Hashable, Comparable {
  public let clock: HLCTimestamp
  public let ref: EntityRef

  public static func < (lhs: ReplayPosition, rhs: ReplayPosition) -> Bool {
    guard lhs.clock == rhs.clock else { return lhs.clock < rhs.clock }
    return lhs.ref < rhs.ref
  }
}

/// What `Replay.step` did with one command.
public enum ReplayStep: Sendable, Hashable {
  /// The walk closed the days before the command's and the handler ran; `outcomes` says how it ended.
  case taken
  /// A command already taken in, wherever it sorts, or any command once replay has halted; the state is unchanged.
  case ignored
  /// The command stopped replay (`halt`).
  case halted
  /// The command sorts before one already taken in, so the days and commands after its place must be replayed; the state is unchanged.
  case outOfOrder
}

public enum ReplayOrderError: ShadowError, Hashable {
  case outOfOrder(ReplayPosition)

  public var code: String { "memoir_replay.out_of_order" }

  public var errorDescription: String? {
    switch self {
    case .outOfOrder(let position): "The command \(position.ref) sorts before the state it was meant to extend."
    }
  }
}

/// Replay derives hero state from the command log: commands in clock order, each applied under its own ruleset version to the state the ones before
/// it left, with the days walked as the reference's rollover gate walks them before every command. It reads only what commands recorded (instants,
/// offsets, `issuedOn`) and never the device's clock or zone data.
public enum Replay {
  /// By the clock on the appended item, then by id, so every device orders the same set the same way.
  public static func ordered(_ commands: [ReplayCommand]) -> [ReplayCommand] {
    commands.sorted { $0.position < $1.position }
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

  /// The whole command log through `step` in replay order, then the days up to the horizon, the app's local day (`IssueClock.stamp` in the zone in force),
  /// closed without commands. The horizon only ever walks forward, and it is applied last, so the state before it is the one later commands extend.
  public static func run(_ commands: [ReplayCommand], through horizon: IssueStamp? = nil) -> ReplayState {
    var state = ReplayState.initial
    for command in ordered(commands) { step(command, to: &state) }
    if let horizon { walk(&state, through: horizon) }
    return state
  }

  /// Extends a state, such as a checkpoint, with commands that all sort after it, then walks to the horizon. A command placed before the state's latest
  /// one, and not already taken in, throws: the state must be rebuilt from an earlier one, and the state passed in is left as it was.
  public static func extend(_ state: ReplayState, with commands: [ReplayCommand], through horizon: IssueStamp? = nil) throws(ReplayOrderError) -> ReplayState {
    var extended = state
    for command in ordered(commands) where step(command, to: &extended) == .outOfOrder { throw .outOfOrder(command.position) }
    if let horizon { walk(&extended, through: horizon) }
    return extended
  }

  /// Takes one command in: the gate closes every day before the command's own (its `issuedOn`, or the day a replaced zone has reached at its instant),
  /// within the catch-up limit, and opens that day, then the handler runs. A command that sorts before the latest one taken is left for a replay from an
  /// earlier state, which is how a command delivered late reopens the days it falls into.
  @discardableResult
  public static func step(_ command: ReplayCommand, to state: inout ReplayState) -> ReplayStep {
    if case .readable(let entry) = command, state.outcomes[entry.record.id] != nil { return .ignored }
    let position = command.position
    if let latest = state.position, position < latest { return .outOfOrder }
    state.position = position
    guard state.halt == nil else { return .ignored }
    guard let admitted = admit(command, to: &state) else { return state.halt == nil ? .ignored : .halted }
    let closing = max(admitted.ruleset.version, state.highestRulesetVersion ?? admitted.ruleset.version)
    let stored = admitted.command
    state.walk(
      to: WalkDriver(
        date: stored.issuedOn, instantMillis: stored.instantMillis, utcOffsetMinutes: stored.utcOffsetMinutes, ruleset: Ruleset.version(closing) ?? admitted.ruleset))
    take(admitted, to: &state)
    return .taken
  }

  /// Closes the days before the horizon's and opens it, under the highest ruleset version replay has seen; nothing moves once replay has halted.
  public static func walk(_ state: inout ReplayState, through horizon: IssueStamp) {
    guard state.halt == nil else { return }
    let ruleset = state.highestRulesetVersion.flatMap(Ruleset.version) ?? .current
    state.walk(to: WalkDriver(date: horizon.issuedOn, instantMillis: horizon.instantMillis, utcOffsetMinutes: horizon.utcOffsetMinutes, ruleset: ruleset))
  }

  /// Runs one command's handler without the day walk, against whatever days the state holds, for vectors that set up the days themselves. A halted
  /// replay takes nothing more, and a command already taken in is not taken again.
  static func apply(_ command: ReplayCommand, to state: inout ReplayState) {
    guard state.halt == nil, let admitted = admit(command, to: &state) else { return }
    take(admitted, to: &state)
  }

  private struct Admitted {
    let command: MemoirCommand
    let body: MemoirCommandBody
    let ruleset: Ruleset
  }

  /// Nil for a command already taken in, or one this app cannot read, which sets `halt`.
  private static func admit(_ command: ReplayCommand, to state: inout ReplayState) -> Admitted? {
    guard case .readable(let entry) = command else {
      state.halt = .unreadableCommand(command.ref)
      return nil
    }
    let stored = entry.record
    guard state.outcomes[stored.id] == nil else { return nil }
    let body: MemoirCommandBody
    do throws(CommandRefusal) {
      body = try MemoirCommandBody(stored)
    } catch {
      if case .unknownType(let type) = error {
        state.halt = .unknownCommandType(command: stored.id, type: type)
        return nil
      }
      state.halt = .unreadableCommand(stored.ref)
      return nil
    }
    guard let ruleset = Ruleset.version(stored.rulesetVersion) else {
      state.halt = .rulesetUnavailable(command: stored.id, version: stored.rulesetVersion)
      return nil
    }
    return Admitted(command: stored, body: body, ruleset: ruleset)
  }

  private static func take(_ admitted: Admitted, to state: inout ReplayState) {
    let stored = admitted.command
    let ruleset = admitted.ruleset
    let context = ApplyContext(command: stored, ruleset: ruleset, accountDay: state.accountDay(issuedOn: stored.issuedOn), order: state.commandCount)
    let outcome: ReplayOutcome
    do throws(ReplayRefusal) {
      outcome = try state.apply(admitted.body, in: context)
    } catch {
      outcome = .refused(error)
      if case .notEnoughCoins(let balance, let required) = error, case .cosmeticPurchase(let cosmetic) = admitted.body {
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

  func settingChange<Value>(_ value: Value, from firstDay: LocalDate) -> SettingChange<Value> {
    SettingChange(firstDay: firstDay, value: value, command: id, order: order)
  }

  func pendingSetting<Value>(_ value: Value) -> PendingSetting<Value> {
    PendingSetting(value: value, command: id, order: order, utcOffsetMinutes: command.utcOffsetMinutes)
  }

  /// The latest day an occurrence may be for and still have begun: the zone's date five minutes on, or the open day if that is later.
  func latestBegunDay(openDay: LocalDate?) -> LocalDate {
    let (ahead, overflow) = instant.addingReportingOverflow(Self.midnightSkewMillis)
    let skewed = overflow ? issuedOn : ((try? MemoirCommand.localDate(instantMillis: ahead, utcOffsetMinutes: command.utcOffsetMinutes)) ?? issuedOn)
    return max(skewed, openDay ?? skewed)
  }
}

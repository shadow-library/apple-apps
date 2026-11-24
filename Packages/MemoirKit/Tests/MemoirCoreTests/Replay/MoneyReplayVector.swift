import Foundation
import ShadowCore
import ShadowStore

@testable import MemoirCore

/// One line of `Fixtures/money/vectors.json`: native money steps with the outcome worked out by hand and the reason it holds.
struct MoneyReplayVector: Decodable {
  struct Step: Decodable {
    let at: String
    let type: String
    let payload: JSONValue?
    let occurrence: ReplayScenario.Step.OccurrenceName?
    let rulesetVersion: Int?
    let clock: Int?
  }

  struct Outcome: Decodable, Equatable, CustomStringConvertible {
    let status: String
    let code: String?

    var description: String { [status, code].compactMap(\.self).joined(separator: " ") }
  }

  struct Amount: Decodable, Equatable {
    let xp: Int
    let coins: Int
  }

  struct Covered: Decodable, Equatable {
    let date: String
    let source: String
  }

  struct Close: Decodable, Equatable {
    struct Fine: Decodable, Equatable {
      let intended: Int
      let applied: Int
      let multiplier: Int
      let from: String
      let through: String
    }

    let budget: String
    let periodStart: String
    let outcome: String
    let deposited: Bool
    let closedOn: String
    let reward: Amount?
    let fine: Fine?
  }

  struct Returner: Decodable, Equatable {
    let date: String
    let lastActiveDate: String
    let daysAbsent: Int
  }

  struct Log: Decodable, Equatable {
    let quest: String
    let date: String
    let xp: Int
  }

  struct Event: Decodable, Equatable {
    let key: String
    let type: String
    let date: String
    let xp: Int
    let coins: Int
  }

  /// Only the members a case names are compared; a member present as null is compared as nil.
  struct State: Decodable {
    let hero: Amount?
    let coveredDays: [Covered]?
    let weekStreak: Int?
    let lastSettledWeekStart: String??
    let savingStreak: Int?
    let lastActivityDay: String??
    let closes: [Close]?
    let debuffs: [String: Int?]?
    let returners: [Returner]?
    let notices: Int?
    let achievements: [String]?
    let logs: [Log]?
    let moneyEvents: [Event]?

    private enum CodingKeys: String, CodingKey {
      case hero, coveredDays, weekStreak, lastSettledWeekStart, savingStreak, lastActivityDay, closes, debuffs, returners, notices, achievements, logs, moneyEvents
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      func nullable(_ key: CodingKeys) throws -> String?? {
        container.contains(key) ? .some(try container.decode(String?.self, forKey: key)) : nil
      }
      hero = try container.decodeIfPresent(Amount.self, forKey: .hero)
      coveredDays = try container.decodeIfPresent([Covered].self, forKey: .coveredDays)
      weekStreak = try container.decodeIfPresent(Int.self, forKey: .weekStreak)
      lastSettledWeekStart = try nullable(.lastSettledWeekStart)
      savingStreak = try container.decodeIfPresent(Int.self, forKey: .savingStreak)
      lastActivityDay = try nullable(.lastActivityDay)
      closes = try container.decodeIfPresent([Close].self, forKey: .closes)
      debuffs = try container.decodeIfPresent([String: Int?].self, forKey: .debuffs)
      returners = try container.decodeIfPresent([Returner].self, forKey: .returners)
      notices = try container.decodeIfPresent(Int.self, forKey: .notices)
      achievements = try container.decodeIfPresent([String].self, forKey: .achievements)
      logs = try container.decodeIfPresent([Log].self, forKey: .logs)
      moneyEvents = try container.decodeIfPresent([Event].self, forKey: .moneyEvents)
    }
  }

  struct Expected: Decodable {
    let steps: [Outcome]
    let state: State
  }

  let id: String
  let reason: String
  let steps: [Step]
  let expected: Expected

  static func all() throws -> [MoneyReplayVector] {
    let text = String(decoding: try MemoirStoreFixture.fixture("money/vectors.json"), as: UTF8.self)
    return try text.split(separator: "\n").map { try JSONDecoder().decode(MoneyReplayVector.self, from: Data($0.utf8)) }
  }
}

/// Runs a vector's steps in list order through `Replay.step`, each command clocked by its `clock` or its place; a command clocked before one already taken
/// replays every command so far from the start, as a device does from its checkpoint before it (a horizon walked before then is not walked again).
struct MoneyReplayRun {
  private(set) var state = ReplayState.initial
  private var entries: [ReplayCommand] = []
  private var commands: [UUID?] = []
  private var names: [String: UUID] = [:]

  static let replica = ReplicaID(MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000eeee"))
  static let moneyEventTypes: Set<HeroEventType> = [.moneyFine, .moneyReward, .moneyLog, .goalMilestone, .goalBought]

  init(_ vector: MoneyReplayVector) throws {
    for (index, step) in vector.steps.enumerated() { try run(step, index: index, in: vector) }
  }

  /// Each command's outcome as the whole log decided it, so a command a later delivery superseded reads as superseded.
  var outcomes: [MoneyReplayVector.Outcome] {
    commands.map { command in
      guard let command else { return MoneyReplayVector.Outcome(status: "horizon", code: nil) }
      switch state.outcomes[command] {
      case .applied?: return MoneyReplayVector.Outcome(status: "applied", code: nil)
      case .superseded?: return MoneyReplayVector.Outcome(status: "superseded", code: nil)
      case .rejected(let rejection)?: return MoneyReplayVector.Outcome(status: "rejected", code: rejection.rawValue)
      case .refused(let refusal)?: return MoneyReplayVector.Outcome(status: "refused", code: refusal.code)
      case nil: return MoneyReplayVector.Outcome(status: "not applied", code: nil)
      }
    }
  }

  func name(_ id: UUID) -> String {
    names.first { $0.value == id }.map { String($0.key.dropFirst()) } ?? id.lowercasedString
  }

  /// A trail key with every named id in it written as its name.
  func named(_ key: String) -> String {
    names.reduce(key) { key, entry in key.replacingOccurrences(of: entry.value.lowercasedString, with: String(entry.key.dropFirst())) }
  }

  private mutating func id(_ name: String) -> UUID {
    if let id = names[name] { return id }
    let id = MemoirStoreFixture.commandID(0x20_0000 + names.count)
    names[name] = id
    return id
  }

  private mutating func resolve(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text) where text.hasPrefix("@"): .string(id(text).lowercasedString)
    case .array(let elements): .array(elements.map { resolve($0) })
    case .object(let members): .object(members.mapValues { resolve($0) })
    default: value
    }
  }

  private mutating func run(_ step: MoneyReplayVector.Step, index: Int, in vector: MoneyReplayVector) throws {
    guard let instant = ReplayScenarioRun.millis(step.at) else { throw MemoirFixtureError(description: "\(vector.id): \(step.at) is not an instant") }
    let issuedOn = try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: 0)
    guard step.type != "horizon" else {
      Replay.walk(&state, through: IssueStamp(instantMillis: instant, utcOffsetMinutes: 0, issuedOn: issuedOn))
      commands.append(nil)
      return
    }
    let payload = resolve(step.payload ?? .object([:])).objectValue ?? [:]
    let occurrence = try step.occurrence.map { Occurrence(quest: id("@\($0.quest)"), date: try MemoirStoreFixture.date($0.date)) }
    let body = try MemoirCommandBody(type: try CommandType(step.type), payload: payload, occurrence: occurrence)
    let command = try MemoirCommand(
      id: MemoirStoreFixture.commandID(index + 1), body: body, instantMillis: instant, utcOffsetMinutes: 0, issuedOn: issuedOn,
      rulesetVersion: step.rulesetVersion ?? Ruleset.v2.version)
    guard let clock = HLCTimestamp(wallMillis: Int64(step.clock ?? index + 1), counter: 0, replica: Self.replica) else {
      throw MemoirFixtureError(description: "\(vector.id): clock")
    }
    let entry = ReplayCommand.readable(AppendedEntry(record: command, clock: clock))
    entries.append(entry)
    commands.append(command.id)
    if Replay.step(entry, to: &state) == .outOfOrder { state = Replay.run(entries) }
  }

  var hero: MoneyReplayVector.Amount { MoneyReplayVector.Amount(xp: state.hero.totalXP, coins: state.hero.coins) }

  var coveredDays: [MoneyReplayVector.Covered] {
    state.money.coveredDays.sorted { $0.key < $1.key }.map { MoneyReplayVector.Covered(date: $0.key.isoString, source: $0.value.source.rawValue) }
  }

  var closes: [MoneyReplayVector.Close] {
    state.money.closes.map { key, close in
      var reward: MoneyReplayVector.Amount?
      var fine: MoneyReplayVector.Close.Fine?
      switch close.result {
      case .rewarded(let amount): reward = MoneyReplayVector.Amount(xp: amount.xp, coins: amount.coins)
      case .fined(let intended, let applied, let debuff):
        fine = MoneyReplayVector.Close.Fine(
          intended: intended, applied: applied, multiplier: debuff.multiplier.thousandths, from: debuff.from.isoString, through: debuff.through.isoString)
      }
      return MoneyReplayVector.Close(
        budget: name(key.budget), periodStart: key.periodStart.isoString, outcome: close.outcome.rawValue, deposited: close.deposited,
        closedOn: close.closedOn.isoString, reward: reward, fine: fine)
    }.sorted { ($0.budget, $0.periodStart) < ($1.budget, $1.periodStart) }
  }

  var returners: [MoneyReplayVector.Returner] {
    state.compassion.returnerEvents.values.sorted { $0.date < $1.date }.map {
      MoneyReplayVector.Returner(date: $0.date.isoString, lastActiveDate: $0.lastActiveDate.isoString, daysAbsent: $0.daysAbsent)
    }
  }

  var logs: [MoneyReplayVector.Log] {
    state.logs.all.filter { $0.value.state != .missed }.map { MoneyReplayVector.Log(quest: name($0.occurrence.quest), date: $0.occurrence.date.isoString, xp: $0.value.xpAwarded) }
      .sorted { ($0.quest, $0.date) < ($1.quest, $1.date) }
  }

  var moneyEvents: [MoneyReplayVector.Event] {
    state.hero.events.filter { Self.moneyEventTypes.contains($0.type) }.map {
      MoneyReplayVector.Event(key: named($0.key), type: $0.type.rawValue, date: $0.date.isoString, xp: $0.xpDelta, coins: $0.coinsDelta)
    }
  }
}

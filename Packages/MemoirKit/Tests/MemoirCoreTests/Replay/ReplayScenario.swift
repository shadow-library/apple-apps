import Foundation
import ShadowCore
import ShadowStore

@testable import MemoirCore

/// One line of `Fixtures/replay/scenarios.json`: native steps, the reference's outcome of each and its state at the end.
struct ReplayScenario: Decodable {
  struct Step: Decodable {
    struct OccurrenceName: Decodable {
      let quest: String
      let date: String
    }

    let at: String
    let type: String
    let occurrence: OccurrenceName?
    let payload: JSONValue?
    let offsetMinutes: Int?
  }

  struct StepOutcome: Decodable, Equatable, CustomStringConvertible {
    let status: String
    let code: String?
    let rejection: String?
    let capacity: Int?
    let capacityWarning: String?

    var description: String { [status, code, rejection, capacity.map { "capacity \($0)" }, capacityWarning].compactMap(\.self).joined(separator: " ") }
  }

  struct Expected: Decodable {
    let steps: [StepOutcome]
    let state: ReplaySnapshot
  }

  let id: String
  let source: String
  let offsetMinutes: Int
  let walk: Bool?
  let steps: [Step]
  let expected: Expected

  static func all() throws -> [ReplayScenario] {
    let text = String(decoding: try MemoirStoreFixture.fixture("replay/scenarios.json"), as: UTF8.self)
    return try text.split(separator: "\n").map { try JSONDecoder().decode(ReplayScenario.self, from: Data($0.utf8)) }
  }
}

/// The reference's state in the shape both sides can produce; collections whose order carries no meaning are sorted.
struct ReplaySnapshot: Decodable, Equatable {
  struct Hero: Decodable, Equatable {
    let totalXP: Int
    let level: Int
    let coins: Int
    let stats: [String: Int]
  }

  struct Event: Decodable, Equatable {
    let key: String
    let type: String
    let date: String
    let xp: Int
    let coins: Int
    let stat: String?
    let statDelta: Int
    let quest: String?
    let state: String?
    let levelAfter: Int
  }

  struct Log: Decodable, Equatable {
    let quest: String
    let date: String
    let state: String
    let xp: Int
    let coins: Int
    let strictness: String
    let stat: String
    let intensityMode: String
    let crownHalves: Int
    let reasonTag: String?
    let hasNote: Bool
    let hasReflection: Bool
    let rescheduledToMin: Int?
    let postponedToDate: String?
  }

  struct Reschedule: Decodable, Equatable {
    let quest: String
    let date: String
    let fromMin: Int?
    let toMin: Int
    let reasonTag: String?
    let hasNote: Bool
  }

  struct Streak: Decodable, Equatable {
    let quest: String
    let currentDays: Int
    let longestDays: Int
    let shields: Int
    let completionsTowardShield: Int
    let pendingShieldGrant: Int
    let runStartDate: String?
    let lastCountedDate: String
  }

  struct Counters: Decodable, Equatable {
    let questsCompleted: Int
    let completionsByStrictness: [String: Int]
    let longestStreakDays: Int
    let longestAnchorStreakDays: Int
    let questsReachingSilverStreak: Int
    let subscriptionsConfirmed: Int
    let receiptsScanned: Int
    let fullHpDays: Int
    let crownsBanked: Int
    let lockedDaysCleared: Int
    let comebackBonusesClaimed: Int
    let returnerRitualsCompleted: Int
    let completionsAfterReturner: Int
    let reasonTaggedEvents: Int
    let activeDays: Int
    let lastActiveCountedDate: String?
    let returnerPending: Bool
  }

  struct Cosmetic: Decodable, Equatable {
    let id: String
    let source: String
    let equipped: Bool
  }

  struct Day: Decodable, Equatable {
    struct Lock: Decodable, Equatable {
      let quests: [String]
      let broken: Bool
    }

    struct Comeback: Decodable, Equatable {
      let armed: Bool
      let fires: Int
      let armedViaRecovery: Bool
    }

    struct Crown: Decodable, Equatable {
      let grantedXP: Int
      let remainingXP: Int
      let grantedCoins: Int
      let remainingCoins: Int
      let periodStart: String
    }

    struct HP: Decodable, Equatable {
      let start: Int
      let end: Int
      let max: Int
    }

    struct Banked: Decodable, Equatable {
      let xp: Int
      let coins: Int
    }

    let date: String
    let closed: Bool
    let intensityMode: String
    let hp: HP?
    let missedCount: Int
    let momentum: String
    let returnerFired: Bool
    let banked: Banked?
    let lock: Lock?
    let comeback: Comeback
    let crown: Crown
  }

  struct ComebackEvent: Decodable, Equatable {
    let date: String
    let kind: String
    let xpBonus: Int
    let coinBonus: Int
  }

  struct Recovery: Decodable, Equatable {
    let date: String
    let state: String
    let sourceQuest: String?
    let triggers: [String]
    let isReturnerDay: Bool
  }

  struct ReturnerEvent: Decodable, Equatable {
    let date: String
    let lastActiveDate: String
    let daysAbsent: Int
    let shieldTarget: String?
    let shieldPending: Bool
  }

  struct Metric: Decodable, Equatable {
    let id: String
    let active: Bool
  }

  struct QuickLog: Decodable, Equatable {
    let entry: String
    let rewarded: Bool
  }

  let hero: Hero
  let events: [Event]
  let logs: [Log]
  let reschedules: [Reschedule]
  let streaks: [Streak]
  let shieldConsumptions: [String]
  let counters: Counters
  let achievements: [String]
  let titles: [String]
  let cosmetics: [Cosmetic]
  let displayedTitle: String?
  let pendingReturnerShields: Int
  let openDay: String?
  let lastActiveDate: String?
  let days: [Day]
  let comebackEvents: [ComebackEvent]
  let recoveries: [Recovery]
  let returnerEvents: [ReturnerEvent]
  let metrics: [Metric]
  let quickLogs: [QuickLog]

  var sorted: ReplaySnapshot {
    ReplaySnapshot(
      hero: hero, events: events, logs: logs.sorted { ($0.quest, $0.date) < ($1.quest, $1.date) },
      reschedules: reschedules.sorted { ($0.quest, $0.date) < ($1.quest, $1.date) }, streaks: streaks.sorted { $0.quest < $1.quest },
      shieldConsumptions: shieldConsumptions.sorted(), counters: counters, achievements: achievements.sorted(), titles: titles.sorted(),
      cosmetics: cosmetics.sorted { $0.id < $1.id }, displayedTitle: displayedTitle, pendingReturnerShields: pendingReturnerShields, openDay: openDay,
      lastActiveDate: lastActiveDate, days: days.sorted { $0.date < $1.date }, comebackEvents: comebackEvents.sorted { ($0.date, $0.kind) < ($1.date, $1.kind) },
      recoveries: recoveries.sorted { $0.date < $1.date }, returnerEvents: returnerEvents.sorted { $0.date < $1.date }, metrics: metrics.sorted { $0.id < $1.id },
      quickLogs: quickLogs.sorted { $0.entry < $1.entry })
  }
}

/// Runs a scenario's steps in step order: through `Replay.step` and `Replay.walk` when the scenario walks the days, otherwise through `Replay.apply`,
/// seeding what the day walk would have written.
struct ReplayScenarioRun {
  private(set) var state = ReplayState.initial
  private(set) var outcomes: [ReplayScenario.StepOutcome] = []
  /// The states `Replay.step` handed out before closing a day, as a checkpoint takes them.
  private(set) var boundaries: [ReplayState] = []
  /// How many steps started from the state decoded from its own canonical JSON.
  private(set) var roundTrips = 0
  private let roundTripping: Bool
  private var names: [String: UUID] = [:]
  private let scenario: ReplayScenario

  static let replica = ReplicaID(MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000ffff"))

  /// `roundTripping` replaces the state with its decoded canonical JSON before every step, as a device resuming from a checkpoint there would; a state
  /// replay could not produce (seeded by hand, or left by the handlers alone without the walk) is refused and kept as it was.
  init(_ scenario: ReplayScenario, roundTripping: Bool = false) throws {
    self.scenario = scenario
    self.roundTripping = roundTripping
    for (index, step) in scenario.steps.enumerated() { try run(step, index: index) }
  }

  func name(of id: UUID?) -> String? {
    guard let id else { return nil }
    return names.first { $0.value == id }.map { String($0.key.dropFirst()) } ?? id.lowercasedString
  }

  private mutating func id(_ name: String) -> UUID {
    if let builtin = BuiltinMetric(rawValue: String(name.dropFirst("@builtin-".count))), name.hasPrefix("@builtin-") { return builtin.id }
    if let id = names[name] { return id }
    let id = MemoirStoreFixture.commandID(0x10_0000 + names.count)
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

  private mutating func occurrence(_ step: ReplayScenario.Step) throws -> Occurrence? {
    guard let name = step.occurrence else { return nil }
    return Occurrence(quest: id("@\(name.quest)"), date: try MemoirStoreFixture.date(name.date))
  }

  private mutating func run(_ step: ReplayScenario.Step, index: Int) throws {
    guard let instant = Self.millis(step.at) else { throw MemoirFixtureError(description: "\(scenario.id): \(step.at) is not an instant") }
    let payload = resolve(step.payload ?? .object([:])).objectValue ?? [:]
    if roundTripping, let decoded = try? ReplayState(canonicalJSON: try state.canonicalJSON()) {
      state = decoded
      roundTrips += 1
    }
    if step.type.hasPrefix("seed.") {
      try seed(step, payload: payload, instant: instant)
      outcomes.append(ReplayScenario.StepOutcome(status: "seed", code: nil, rejection: nil, capacity: nil, capacityWarning: nil))
      return
    }
    let offset = step.offsetMinutes ?? scenario.offsetMinutes
    let issuedOn = try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offset)
    if step.type == "horizon" {
      Replay.walk(&state, through: IssueStamp(instantMillis: instant, utcOffsetMinutes: offset, issuedOn: issuedOn))
      outcomes.append(ReplayScenario.StepOutcome(status: "horizon", code: nil, rejection: nil, capacity: nil, capacityWarning: nil))
      return
    }
    let body = try MemoirCommandBody(type: try CommandType(step.type), payload: payload, occurrence: try occurrence(step))
    let command = try MemoirCommand(
      id: MemoirStoreFixture.commandID(index + 1), body: body, instantMillis: instant, utcOffsetMinutes: offset, issuedOn: issuedOn,
      rulesetVersion: Ruleset.v1.version)
    var capacity: LockCapacity?
    if case .planSetLock(.locked(let quests)) = body {
      capacity = state.lockCapacity(on: state.accountDay(issuedOn: issuedOn), plannedLoad: quests.count, ruleset: .v1)
    }
    guard let clock = HLCTimestamp(wallMillis: Int64(index), counter: 0, replica: Self.replica) else { throw MemoirFixtureError(description: "clock") }
    let entry = ReplayCommand.readable(AppendedEntry(record: command, clock: clock))
    if scenario.walk == true {
      var captured = [ReplayState]()
      Replay.step(entry, to: &state) { (boundary: ReplayState) in captured.append(boundary) }
      boundaries += captured
    } else {
      Replay.apply(entry, to: &state)
    }
    outcomes.append(Self.outcome(state.outcomes[command.id], capacity: capacity))
  }

  private static func outcome(_ outcome: ReplayOutcome?, capacity: LockCapacity?) -> ReplayScenario.StepOutcome {
    switch outcome {
    case .applied?:
      ReplayScenario.StepOutcome(
        status: "applied", code: nil, rejection: nil, capacity: capacity?.capacity.capacity, capacityWarning: capacity?.warning.rawValue)
    case .superseded?: ReplayScenario.StepOutcome(status: "superseded", code: nil, rejection: nil, capacity: nil, capacityWarning: nil)
    case .rejected(let rejection)?: ReplayScenario.StepOutcome(status: "rejected", code: nil, rejection: rejection.rawValue, capacity: nil, capacityWarning: nil)
    case .refused(let refusal)?: ReplayScenario.StepOutcome(status: "refused", code: refusal.referenceCode, rejection: nil, capacity: nil, capacityWarning: nil)
    case nil: ReplayScenario.StepOutcome(status: "not applied", code: nil, rejection: nil, capacity: nil, capacityWarning: nil)
    }
  }

  private mutating func seed(_ step: ReplayScenario.Step, payload: [String: JSONValue], instant: Int64) throws {
    func date(_ key: String) throws -> LocalDate {
      guard let text = payload[key]?.stringValue else { throw MemoirFixtureError(description: "\(scenario.id): \(step.type) needs \(key)") }
      return try MemoirStoreFixture.date(text)
    }
    func integer(_ key: String) -> Int { payload[key]?.intValue.map { Int($0) } ?? 0 }
    switch step.type {
    case "seed.day":
      let day = try date("date")
      var seeded = ReplayDay(
        date: day, intensityMode: IntensityMode(rawValue: payload["intensityMode"]?.stringValue ?? "standard") ?? .standard, rulesetVersion: 1,
        comeback: ComebackDayState(armed: payload["comebackArmed"]?.boolValue ?? false, fires: 0, armedViaRecovery: false),
        momentum: MomentumBucket(rawValue: payload["momentum"]?.stringValue ?? "steady") ?? .steady)
      seeded.isClosed = payload["closed"]?.boolValue ?? false
      state.days[day] = seeded
    case "seed.recovery":
      let day = try date("date")
      state.compassion.recoveries[day] = RecoveryQuest(
        id: id("@recovery-\(day)"), date: day, sourceQuest: payload["sourceQuest"]?.stringValue.flatMap(UUID.init(uuidString:)), triggerLogs: [],
        isReturnerDay: false, state: .pending)
    case "seed.miss":
      guard let occurrence = try occurrence(step), let quest = state.quests[occurrence.quest] else { throw MemoirFixtureError(description: "\(scenario.id): seed.miss") }
      let strictness = quest.schedule.strictness
      state.logs[occurrence] = QuestLogEntry(
        id: id("@miss-\(occurrence.date)"), state: .missed, xpAwarded: 0, coinsAwarded: 0, statAffinity: quest.schedule.statAffinity, strictness: strictness,
        intensityModeAtLog: .standard, crownSliceWeight: Ruleset.v1.crownWeight(for: strictness), rulesetVersion: 1, createdAtMillis: instant)
    case "seed.openDay":
      state.openDay = try date("date")
    case "seed.coins":
      state.hero.coins = integer("coins")
    case "seed.returnerShields":
      state.compassion.pendingReturnerShields = integer("shields")
    default:
      throw MemoirFixtureError(description: "\(scenario.id): unknown seed \(step.type)")
    }
  }

  static func millis(_ text: String) -> Int64? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
  }

  /// The native state in the reference snapshot's shape, its ledger keys naming the occurrence or day as the generator writes them.
  var snapshot: ReplaySnapshot {
    let hero = state.hero
    return ReplaySnapshot(
      hero: ReplaySnapshot.Hero(
        totalXP: hero.totalXP, level: hero.level, coins: hero.coins, stats: Dictionary(uniqueKeysWithValues: hero.stats.entries.map { ($0.key.rawValue, $0.value) })),
      events: hero.events.map { event in
        ReplaySnapshot.Event(
          key: key(of: event), type: event.type.rawValue, date: event.date.isoString, xp: event.xpDelta, coins: event.coinsDelta, stat: event.statAffinity?.rawValue,
          statDelta: event.statDelta, quest: name(of: event.quest), state: event.state?.rawValue, levelAfter: event.levelAfter)
      },
      logs: state.logs.all.map { occurrence, log in
        ReplaySnapshot.Log(
          quest: name(of: occurrence.quest) ?? "", date: occurrence.date.isoString, state: log.state.rawValue, xp: log.xpAwarded, coins: log.coinsAwarded,
          strictness: log.strictness.rawValue, stat: log.statAffinity.rawValue, intensityMode: log.intensityModeAtLog.rawValue, crownHalves: log.crownSliceWeight.halves,
          reasonTag: log.reasonTag?.rawValue, hasNote: log.reasonNote != nil, hasReflection: log.reflection != nil, rescheduledToMin: log.rescheduledToMinute,
          postponedToDate: log.postponedToDate?.isoString)
      },
      reschedules: state.reschedules.all.map { occurrence, entry in
        ReplaySnapshot.Reschedule(
          quest: name(of: occurrence.quest) ?? "", date: occurrence.date.isoString, fromMin: entry.fromMinute, toMin: entry.toMinute, reasonTag: entry.reasonTag?.rawValue,
          hasNote: entry.reasonNote != nil)
      },
      streaks: state.streaks.map { quest, streak in
        ReplaySnapshot.Streak(
          quest: name(of: quest) ?? "", currentDays: streak.state.currentDays, longestDays: streak.state.longestDays, shields: streak.state.shields,
          completionsTowardShield: streak.state.completionsTowardShield, pendingShieldGrant: streak.state.pendingShieldGrant, runStartDate: streak.runStartDate?.isoString,
          lastCountedDate: streak.lastCountedDate?.isoString ?? "")
      },
      shieldConsumptions: state.shieldConsumptions.map { "\(name(of: $0.quest) ?? ""):\($0.date)" }, counters: counters,
      achievements: state.progression.achievements.keys.map(\.rawValue), titles: state.progression.titles.keys.map(\.rawValue),
      cosmetics: state.progression.cosmetics.map { ReplaySnapshot.Cosmetic(id: $0.key.rawValue, source: $0.value.source.rawValue, equipped: $0.value.equipped) },
      displayedTitle: state.progression.displayedTitle?.rawValue, pendingReturnerShields: state.compassion.pendingReturnerShields,
      openDay: state.openDay?.isoString, lastActiveDate: state.compassion.lastActiveDate?.isoString, days: state.days.values.map(day(_:)),
      comebackEvents: state.days.values.flatMap { day in
        day.comebackEvents.values.map { ReplaySnapshot.ComebackEvent(date: day.date.isoString, kind: $0.kind.rawValue, xpBonus: $0.xpBonus, coinBonus: $0.coinBonus) }
      },
      recoveries: state.compassion.recoveries.values.map { recovery in
        ReplaySnapshot.Recovery(
          date: recovery.date.isoString, state: recovery.state.rawValue, sourceQuest: name(of: recovery.sourceQuest), triggers: recovery.triggerLogs.map(occurrence(ofLog:)),
          isReturnerDay: recovery.isReturnerDay)
      },
      returnerEvents: state.compassion.returnerEvents.values.map { event in
        ReplaySnapshot.ReturnerEvent(
          date: event.date.isoString, lastActiveDate: event.lastActiveDate.isoString, daysAbsent: event.daysAbsent, shieldTarget: name(of: event.shieldTarget),
          shieldPending: event.shieldPending)
      },
      metrics: state.records.metrics.map { ReplaySnapshot.Metric(id: name(of: $0.key) ?? "", active: $0.value.isActive) },
      quickLogs: state.records.quickLogs.map { ReplaySnapshot.QuickLog(entry: name(of: $0.key) ?? "", rewarded: $0.value.rewarded) })
  }

  private var counters: ReplaySnapshot.Counters {
    let progression = state.progression
    let counters = progression.counters
    return ReplaySnapshot.Counters(
      questsCompleted: counters.questsCompleted,
      completionsByStrictness: Dictionary(uniqueKeysWithValues: counters.completionsByStrictness.entries.map { ($0.key.rawValue, $0.value) }),
      longestStreakDays: counters.longestStreakDays, longestAnchorStreakDays: counters.longestAnchorStreakDays,
      questsReachingSilverStreak: counters.questsReachingSilverStreak, subscriptionsConfirmed: counters.subscriptionsConfirmed, receiptsScanned: counters.receiptsScanned,
      fullHpDays: counters.fullHPDays, crownsBanked: counters.crownsBanked, lockedDaysCleared: counters.lockedDaysCleared,
      comebackBonusesClaimed: counters.comebackBonusesClaimed, returnerRitualsCompleted: counters.returnerRitualsCompleted,
      completionsAfterReturner: counters.completionsAfterReturner, reasonTaggedEvents: counters.reasonTaggedEvents, activeDays: counters.activeDays,
      lastActiveCountedDate: progression.lastActiveCountedDate?.isoString, returnerPending: progression.returnerPending)
  }

  private func day(_ day: ReplayDay) -> ReplaySnapshot.Day {
    let crown = day.crown
    return ReplaySnapshot.Day(
      date: day.date.isoString, closed: day.isClosed, intensityMode: day.intensityMode.rawValue,
      hp: day.hp.map { ReplaySnapshot.Day.HP(start: $0.hpStart, end: $0.hpEnd, max: $0.hpMax) }, missedCount: day.missedCount, momentum: day.momentum.rawValue,
      returnerFired: day.returnerFired, banked: crown?.banked.map { ReplaySnapshot.Day.Banked(xp: $0.xp, coins: $0.coins) },
      lock: day.lock.map { ReplaySnapshot.Day.Lock(quests: $0.quests.map { name(of: $0) ?? "" }, broken: !$0.isActive) },
      comeback: ReplaySnapshot.Day.Comeback(armed: day.comeback.armed, fires: day.comeback.fires, armedViaRecovery: day.comeback.armedViaRecovery),
      crown: ReplaySnapshot.Day.Crown(
        grantedXP: crown?.state.grantedXP ?? 0, remainingXP: crown?.state.remainingXP ?? 0, grantedCoins: crown?.state.grantedCoins ?? 0,
        remainingCoins: crown?.state.remainingCoins ?? 0, periodStart: (crown?.periodStart ?? day.date).isoString))
  }

  private func key(of event: HeroEvent) -> String {
    switch event.type {
    case .questComplete, .questPartial, .questLate: "xp:\(name(of: event.quest) ?? ""):\(event.date)"
    case .recoveryCompleted: "recovery_completed:\(event.date)"
    case .recoveryExpired:
      "recovery_expired:\(state.compassion.recoveries.values.first { event.key == "recovery_expired_\($0.id.lowercasedString)" }?.date.isoString ?? "")"
    case .crownForfeit: "crownforfeit:\(name(of: event.quest) ?? ""):\(event.date)"
    default: event.key
    }
  }

  private func occurrence(ofLog id: UUID) -> String {
    state.logs.all.first { $0.value.id == id }.map { "\(name(of: $0.occurrence.quest) ?? ""):\($0.occurrence.date)" } ?? id.lowercasedString
  }
}

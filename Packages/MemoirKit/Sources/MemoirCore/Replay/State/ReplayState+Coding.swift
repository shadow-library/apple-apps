import Foundation

/// A replay checkpoint's body. Maps keyed by id and sets encode as arrays in a fixed order and date- or token-keyed maps as objects, so equal states encode
/// to the same canonical JSON; the recurrence cursors are a cache and are never encoded. Decoding refuses another `codingVersion` and a state whose parts
/// contradict each other.
extension ReplayState: Codable {
  public static let codingVersion = 4

  private enum CodingKeys: String, CodingKey {
    case version
    case quests
    case logs
    case reschedules
    case reasonedReschedules
    case streaks
    case shieldConsumptions
    case hero
    case progression
    case compassion
    case money
    case days
    case settings
    case records
    case position
    case openDay
    case latestIssuedOn
    case latestUtcOffsetMinutes
    case highestRulesetVersion
    case outcomes
    case notices
    case halt
    case commandCount
    case questCount
    case earliestQuestDay
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.codingVersion else {
      throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Replay state version \(version) is not \(Self.codingVersion).")
    }
    var state = ReplayState()
    state.quests = try container.decodeMap(ReplayQuest.self, forKey: .quests)
    state.logs = try container.decode(OccurrenceTable<QuestLogEntry>.self, forKey: .logs)
    state.reschedules = try container.decode(OccurrenceTable<RescheduleEntry>.self, forKey: .reschedules)
    state.reasonedReschedules = try container.decode([LocalDate: Int].self, forKey: .reasonedReschedules)
    state.streaks = try container.decodeMap(QuestStreak.self, forKey: .streaks)
    state.shieldConsumptions = try container.decodeSet(Occurrence.self, forKey: .shieldConsumptions)
    state.hero = try container.decode(HeroLedger.self, forKey: .hero)
    state.progression = try container.decode(ProgressionState.self, forKey: .progression)
    state.compassion = try container.decode(CompassionState.self, forKey: .compassion)
    state.money = try container.decode(MoneyState.self, forKey: .money)
    state.days = try container.decode([LocalDate: ReplayDay].self, forKey: .days)
    state.settings = try container.decode(ReplaySettings.self, forKey: .settings)
    state.records = try container.decode(RecordIndex.self, forKey: .records)
    state.position = try container.decodeIfPresent(ReplayPosition.self, forKey: .position)
    state.openDay = try container.decodeIfPresent(LocalDate.self, forKey: .openDay)
    state.latestIssuedOn = try container.decodeIfPresent(LocalDate.self, forKey: .latestIssuedOn)
    state.latestUtcOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .latestUtcOffsetMinutes)
    state.highestRulesetVersion = try container.decodeIfPresent(Int.self, forKey: .highestRulesetVersion)
    state.outcomes = try container.decodeMap(ReplayOutcome.self, forKey: .outcomes)
    state.notices = try container.decode([ReplayNotice].self, forKey: .notices)
    state.halt = try container.decodeIfPresent(ReplayHalt.self, forKey: .halt)
    state.commandCount = try container.decode(Int.self, forKey: .commandCount)
    state.questCount = try container.decode(Int.self, forKey: .questCount)
    state.earliestQuestDay = try container.decodeIfPresent(LocalDate.self, forKey: .earliestQuestDay)
    if let contradiction = state.contradiction {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: contradiction))
    }
    self = state
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.codingVersion, forKey: .version)
    try container.encodeMap(quests, forKey: .quests)
    try container.encode(logs, forKey: .logs)
    try container.encode(reschedules, forKey: .reschedules)
    try container.encode(reasonedReschedules, forKey: .reasonedReschedules)
    try container.encodeMap(streaks, forKey: .streaks)
    try container.encodeSet(shieldConsumptions, by: Occurrence.precedes, forKey: .shieldConsumptions)
    try container.encode(hero, forKey: .hero)
    try container.encode(progression, forKey: .progression)
    try container.encode(compassion, forKey: .compassion)
    try container.encode(money, forKey: .money)
    try container.encode(days, forKey: .days)
    try container.encode(settings, forKey: .settings)
    try container.encode(records, forKey: .records)
    try container.encodeIfPresent(position, forKey: .position)
    try container.encodeIfPresent(openDay, forKey: .openDay)
    try container.encodeIfPresent(latestIssuedOn, forKey: .latestIssuedOn)
    try container.encodeIfPresent(latestUtcOffsetMinutes, forKey: .latestUtcOffsetMinutes)
    try container.encodeIfPresent(highestRulesetVersion, forKey: .highestRulesetVersion)
    try container.encodeMap(outcomes, forKey: .outcomes)
    try container.encode(notices, forKey: .notices)
    try container.encodeIfPresent(halt, forKey: .halt)
    try container.encode(commandCount, forKey: .commandCount)
    try container.encode(questCount, forKey: .questCount)
    try container.encodeIfPresent(earliestQuestDay, forKey: .earliestQuestDay)
  }

  /// What a decoded state says that replay could never have left; nil when its parts agree.
  private var contradiction: String? {
    if quests.contains(where: { $0.key != $0.value.id }) { return "A quest is filed under another quest's id." }
    if quests.count != questCount || Set(quests.values.map(\.createdOrder)) != Set((0..<max(0, questCount)).map { $0 + 1 }) {
      return "Quest creation orders are not 1 to the number of quests created."
    }
    if days.contains(where: { $0.key != $0.value.date }) { return "A day is filed under another date." }
    if compassion.recoveries.contains(where: { $0.key != $0.value.date }) || compassion.returnerEvents.contains(where: { $0.key != $0.value.date }) {
      return "A Recovery quest or Returner event is filed under another date."
    }
    if outcomes.count != commandCount { return "The command count is not the number of commands with an outcome." }
    if position == nil && commandCount > 0 { return "Commands were taken in without a position." }
    let counts = [commandCount, compassion.pendingReturnerShields] + reasonedReschedules.values + records.sideQuestsRewarded.values
    if counts.contains(where: { $0 < 0 }) { return "A count is negative." }
    if let open = openDay, days[open] == nil { return "The open day has no day row." }
    return moneyContradiction
  }

  private var moneyContradiction: String? {
    if money.weekStreak < 0 || money.savingStreak < 0 { return "A money streak is negative." }
    let commands = money.coveredDays.values.map(\.command) + money.closes.values.map(\.command)
    if commands.contains(where: { outcomes[$0] != .applied }) { return "Money state names a command replay did not apply." }
    for close in money.closes.values {
      guard case .fined(let intended, let applied, let debuff) = close.result else { continue }
      if applied < 0 || applied > intended { return "A close took more coins than its fine, or fewer than none." }
      if debuff.command != close.command || debuff.from != close.closedOn || debuff.through < debuff.from { return "A close's debuff is not its own." }
    }
    let spans = Set(
      money.closes.values.compactMap { close -> MoneyDebuffSpan? in
        guard case .fined(_, _, let debuff) = close.result else { return nil }
        return debuff
      })
    if !money.debuffs.allSatisfy(spans.contains) { return "A debuff has no close." }
    return nil
  }
}

extension MoneyState: Codable {
  private enum CodingKeys: String, CodingKey {
    case coveredDays
    case lastActivityDay
    case weekStreak
    case lastSettledWeekStart
    case savingStreak
    case closes
    case milestones
    case goalsBought
    case debuffs
  }

  private struct CloseEntry: Codable {
    let key: MoneyCloseKey
    let close: MoneyClose
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var state = MoneyState()
    state.coveredDays = try container.decode([LocalDate: MoneyCoverage].self, forKey: .coveredDays)
    state.lastActivityDay = try container.decodeIfPresent(LocalDate.self, forKey: .lastActivityDay)
    state.weekStreak = try container.decode(Int.self, forKey: .weekStreak)
    state.lastSettledWeekStart = try container.decodeIfPresent(LocalDate.self, forKey: .lastSettledWeekStart)
    state.savingStreak = try container.decode(Int.self, forKey: .savingStreak)
    for entry in try container.decode([CloseEntry].self, forKey: .closes) {
      guard state.closes.updateValue(entry.close, forKey: entry.key) == nil else {
        throw DecodingError.dataCorruptedError(forKey: .closes, in: container, debugDescription: "A period is closed twice.")
      }
    }
    state.milestones = try container.decodeSet(GoalMilestoneKey.self, forKey: .milestones)
    state.goalsBought = try container.decodeSet(UUID.self, forKey: .goalsBought)
    state.debuffs = try container.decode([MoneyDebuffSpan].self, forKey: .debuffs)
    self = state
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(coveredDays, forKey: .coveredDays)
    try container.encodeIfPresent(lastActivityDay, forKey: .lastActivityDay)
    try container.encode(weekStreak, forKey: .weekStreak)
    try container.encodeIfPresent(lastSettledWeekStart, forKey: .lastSettledWeekStart)
    try container.encode(savingStreak, forKey: .savingStreak)
    try container.encode(closes.sorted { MoneyCloseKey.precedes($0.key, $1.key) }.map { CloseEntry(key: $0.key, close: $0.value) }, forKey: .closes)
    try container.encodeSet(milestones, by: GoalMilestoneKey.precedes, forKey: .milestones)
    try container.encodeSet(goalsBought, by: UUID.precedes, forKey: .goalsBought)
    try container.encode(debuffs, forKey: .debuffs)
  }
}

extension MoneyCloseKey {
  static func precedes(_ lhs: MoneyCloseKey, _ rhs: MoneyCloseKey) -> Bool {
    guard lhs.budget == rhs.budget else { return UUID.precedes(lhs.budget, rhs.budget) }
    return lhs.periodStart < rhs.periodStart
  }
}

extension GoalMilestoneKey {
  static func precedes(_ lhs: GoalMilestoneKey, _ rhs: GoalMilestoneKey) -> Bool {
    guard lhs.goal == rhs.goal else { return UUID.precedes(lhs.goal, rhs.goal) }
    return lhs.milestone.rawValue < rhs.milestone.rawValue
  }
}

extension MoneyClose: Codable {
  private enum CodingKeys: String, CodingKey {
    case command
    case outcome
    case deposited
    case closedOn
    case reward
    case fine
    case fineApplied
    case debuff
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let result: MoneyCloseResult
    switch (try container.decodeIfPresent(RewardAmount.self, forKey: .reward), try container.decodeIfPresent(Int.self, forKey: .fine)) {
    case (let reward?, nil): result = .rewarded(reward)
    case (nil, let fine?):
      result = .fined(
        intended: fine, applied: try container.decode(Int.self, forKey: .fineApplied), debuff: try container.decode(MoneyDebuffSpan.self, forKey: .debuff))
    default: throw DecodingError.dataCorruptedError(forKey: .reward, in: container, debugDescription: "A close is either rewarded or fined.")
    }
    self.init(
      command: try container.decode(UUID.self, forKey: .command), outcome: try container.decode(BudgetCloseOutcome.self, forKey: .outcome),
      deposited: try container.decode(Bool.self, forKey: .deposited), closedOn: try container.decode(LocalDate.self, forKey: .closedOn), result: result)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(command, forKey: .command)
    try container.encode(outcome, forKey: .outcome)
    try container.encode(deposited, forKey: .deposited)
    try container.encode(closedOn, forKey: .closedOn)
    switch result {
    case .rewarded(let reward): try container.encode(reward, forKey: .reward)
    case .fined(let intended, let applied, let debuff):
      try container.encode(intended, forKey: .fine)
      try container.encode(applied, forKey: .fineApplied)
      try container.encode(debuff, forKey: .debuff)
    }
  }
}

extension RecordIndex: Codable {
  private enum CodingKeys: String, CodingKey {
    case quickLogs
    case weightDates
    case sideQuestsRewarded
    case mealPresets
    case metrics
    case expenses
    case subscriptions
    case confirmedCycles
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var index = RecordIndex()
    index.quickLogs = try container.decodeMap(QuickLogOutcome.self, forKey: .quickLogs)
    index.weightDates = try container.decodeSet(LocalDate.self, forKey: .weightDates)
    index.sideQuestsRewarded = try container.decode([LocalDate: Int].self, forKey: .sideQuestsRewarded)
    index.mealPresets = try container.decodeSet(UUID.self, forKey: .mealPresets)
    index.metrics = try container.decodeMap(ReplayMetric.self, forKey: .metrics)
    index.expenses = try container.decodeSet(UUID.self, forKey: .expenses)
    index.subscriptions = try container.decodeSet(UUID.self, forKey: .subscriptions)
    index.confirmedCycles = try container.decodeSet(CycleConfirmation.self, forKey: .confirmedCycles)
    self = index
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeMap(quickLogs, forKey: .quickLogs)
    try container.encodeSet(weightDates, by: <, forKey: .weightDates)
    try container.encode(sideQuestsRewarded, forKey: .sideQuestsRewarded)
    try container.encodeSet(mealPresets, by: UUID.precedes, forKey: .mealPresets)
    try container.encodeMap(metrics, forKey: .metrics)
    try container.encodeSet(expenses, by: UUID.precedes, forKey: .expenses)
    try container.encodeSet(subscriptions, by: UUID.precedes, forKey: .subscriptions)
    try container.encodeSet(confirmedCycles, by: CycleConfirmation.precedes, forKey: .confirmedCycles)
  }
}

extension Occurrence: Codable {
  private enum CodingKeys: String, CodingKey {
    case quest
    case date
  }

  static func precedes(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
    guard lhs.date == rhs.date else { return lhs.date < rhs.date }
    return UUID.precedes(lhs.quest, rhs.quest)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(quest: try container.decode(UUID.self, forKey: .quest), date: try container.decode(LocalDate.self, forKey: .date))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(quest, forKey: .quest)
    try container.encode(date, forKey: .date)
  }
}

extension CycleConfirmation: Codable {
  private enum CodingKeys: String, CodingKey {
    case subscription
    case billingDate
  }

  static func precedes(_ lhs: CycleConfirmation, _ rhs: CycleConfirmation) -> Bool {
    guard lhs.subscription == rhs.subscription else { return UUID.precedes(lhs.subscription, rhs.subscription) }
    return lhs.billingDate < rhs.billingDate
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(subscription: try container.decode(UUID.self, forKey: .subscription), billingDate: try container.decode(LocalDate.self, forKey: .billingDate))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(subscription, forKey: .subscription)
    try container.encode(billingDate, forKey: .billingDate)
  }
}

extension UUID {
  static func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
  }
}

private struct MapEntry<Value: Codable>: Codable {
  let key: UUID
  let value: Value
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeMap<Value: Codable>(_ map: [UUID: Value], forKey key: Key) throws {
    try encode(map.sorted { UUID.precedes($0.key, $1.key) }.map { MapEntry(key: $0.key, value: $0.value) }, forKey: key)
  }

  fileprivate mutating func encodeSet<Element: Encodable>(_ set: Set<Element>, by precedes: (Element, Element) -> Bool, forKey key: Key) throws {
    try encode(set.sorted(by: precedes), forKey: key)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeMap<Value: Codable>(_: Value.Type, forKey key: Key) throws -> [UUID: Value] {
    var map = [UUID: Value]()
    for entry in try decode([MapEntry<Value>].self, forKey: key) {
      guard map.updateValue(entry.value, forKey: entry.key) == nil else {
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "The id \(entry.key) is listed twice.")
      }
    }
    return map
  }

  fileprivate func decodeSet<Element: Decodable & Hashable>(_: Element.Type, forKey key: Key) throws -> Set<Element> {
    let elements = try decode([Element].self, forKey: key)
    let set = Set(elements)
    guard set.count == elements.count else { throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "A set lists an element twice.") }
    return set
  }
}

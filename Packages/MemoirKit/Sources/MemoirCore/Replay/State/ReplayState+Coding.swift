import Foundation

/// A replay checkpoint's body. Maps keyed by id and sets encode as arrays in a fixed order and date- or token-keyed maps as objects, so equal states encode
/// to the same canonical JSON; the recurrence cursors are a cache and are never encoded. Decoding refuses another `codingVersion` and a state whose parts
/// contradict each other.
extension ReplayState: Codable {
  public static let codingVersion = 1

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
    case days
    case settings
    case records
    case position
    case openDay
    case latestIssuedOn
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
    state.days = try container.decode([LocalDate: ReplayDay].self, forKey: .days)
    state.settings = try container.decode(ReplaySettings.self, forKey: .settings)
    state.records = try container.decode(RecordIndex.self, forKey: .records)
    state.position = try container.decodeIfPresent(ReplayPosition.self, forKey: .position)
    state.openDay = try container.decodeIfPresent(LocalDate.self, forKey: .openDay)
    state.latestIssuedOn = try container.decodeIfPresent(LocalDate.self, forKey: .latestIssuedOn)
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
    try container.encode(days, forKey: .days)
    try container.encode(settings, forKey: .settings)
    try container.encode(records, forKey: .records)
    try container.encodeIfPresent(position, forKey: .position)
    try container.encodeIfPresent(openDay, forKey: .openDay)
    try container.encodeIfPresent(latestIssuedOn, forKey: .latestIssuedOn)
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
    return nil
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

import Foundation
import ShadowText

/// What replay derives that the insight context reads, as plain values, so the assembly does not depend on replay's types.
public protocol InsightReplaySource: Sendable {
  /// The whole history; the assembly picks the window. `includingText` is false unless the owner consented to journal, reflection and reason text, and
  /// the assembly drops any text it is given anyway.
  func insightState(includingText: Bool) async throws(InsightError) -> InsightReplayState
}

public struct InsightReplayState: Sendable, Equatable {
  public var profile: InsightProfile
  public var quests: [InsightQuestState]
  public var questLogs: [InsightQuestLog]
  public var heroEvents: [InsightHeroEvent]
  public var dailyStates: [InsightDailyState]
  public var progressionEvents: [InsightProgressionEvent]

  public init(
    profile: InsightProfile, quests: [InsightQuestState] = [], questLogs: [InsightQuestLog] = [], heroEvents: [InsightHeroEvent] = [],
    dailyStates: [InsightDailyState] = [], progressionEvents: [InsightProgressionEvent] = []
  ) {
    self.profile = profile
    self.quests = quests
    self.questLogs = questLogs
    self.heroEvents = heroEvents
    self.dailyStates = dailyStates
    self.progressionEvents = progressionEvents
  }
}

public struct InsightProfile: Sendable, Equatable {
  public var timeZone: String
  public var intensityMode: IntensityMode

  public init(timeZone: String, intensityMode: IntensityMode) {
    self.timeZone = timeZone
    self.intensityMode = intensityMode
  }
}

/// A quest's replayed schedule; its name and reminder come from its record.
public struct InsightQuestState: Sendable, Equatable {
  public var quest: UUID
  public var startTimeMinutes: Int?
  public var durationMinutes: Int?
  public var statAffinity: StatAffinity?
  public var strictness: Strictness
  public var recurrence: RecurrenceRule?
  public var active: Bool

  public init(
    quest: UUID, startTimeMinutes: Int? = nil, durationMinutes: Int? = nil, statAffinity: StatAffinity? = nil, strictness: Strictness, recurrence: RecurrenceRule? = nil,
    active: Bool = true
  ) {
    self.quest = quest
    self.startTimeMinutes = startTimeMinutes
    self.durationMinutes = durationMinutes
    self.statAffinity = statAffinity
    self.strictness = strictness
    self.recurrence = recurrence
    self.active = active
  }
}

public struct InsightQuestLog: Sendable, Equatable {
  public var quest: UUID
  public var date: LocalDate
  public var state: QuestLogState
  public var xpAwarded: Int
  public var coinsAwarded: Int
  public var strictness: Strictness
  public var intensityModeAtLog: IntensityMode
  public var reasonTag: String?
  public var rescheduledToMinutes: Int?
  public var postponedToDate: LocalDate?
  public var performedAtMillis: Int64?
  public var reasonNote: String?
  public var reflectionText: String?

  public init(
    quest: UUID, date: LocalDate, state: QuestLogState, xpAwarded: Int = 0, coinsAwarded: Int = 0, strictness: Strictness, intensityModeAtLog: IntensityMode,
    reasonTag: String? = nil, rescheduledToMinutes: Int? = nil, postponedToDate: LocalDate? = nil, performedAtMillis: Int64? = nil, reasonNote: String? = nil,
    reflectionText: String? = nil
  ) {
    self.quest = quest
    self.date = date
    self.state = state
    self.xpAwarded = xpAwarded
    self.coinsAwarded = coinsAwarded
    self.strictness = strictness
    self.intensityModeAtLog = intensityModeAtLog
    self.reasonTag = reasonTag
    self.rescheduledToMinutes = rescheduledToMinutes
    self.postponedToDate = postponedToDate
    self.performedAtMillis = performedAtMillis
    self.reasonNote = reasonNote
    self.reflectionText = reflectionText
  }
}

public struct InsightHeroEvent: Sendable, Equatable {
  public var type: String
  public var quest: UUID?
  public var state: QuestLogState?
  public var xpDelta: Int
  public var coinsDelta: Int
  public var statAffinity: StatAffinity?
  public var statDelta: Int
  public var levelAfter: Int?
  public var achievement: String?
  public var date: LocalDate

  public init(
    type: String, quest: UUID? = nil, state: QuestLogState? = nil, xpDelta: Int = 0, coinsDelta: Int = 0, statAffinity: StatAffinity? = nil, statDelta: Int = 0,
    levelAfter: Int? = nil, achievement: String? = nil, date: LocalDate
  ) {
    self.type = type
    self.quest = quest
    self.state = state
    self.xpDelta = xpDelta
    self.coinsDelta = coinsDelta
    self.statAffinity = statAffinity
    self.statDelta = statDelta
    self.levelAfter = levelAfter
    self.achievement = achievement
    self.date = date
  }
}

public struct InsightDailyState: Sendable, Equatable {
  public var date: LocalDate
  public var intensityMode: IntensityMode
  public var hpStart: Int
  public var hpEnd: Int
  public var hpMax: Int
  public var crownXPGranted: Int
  public var crownBankedXP: Int
  public var momentumBucket: String?
  public var missedCount: Int

  public init(
    date: LocalDate, intensityMode: IntensityMode, hpStart: Int, hpEnd: Int, hpMax: Int, crownXPGranted: Int = 0, crownBankedXP: Int = 0, momentumBucket: String? = nil,
    missedCount: Int = 0
  ) {
    self.date = date
    self.intensityMode = intensityMode
    self.hpStart = hpStart
    self.hpEnd = hpEnd
    self.hpMax = hpMax
    self.crownXPGranted = crownXPGranted
    self.crownBankedXP = crownBankedXP
    self.momentumBucket = momentumBucket
    self.missedCount = missedCount
  }
}

/// The compassion trail and the earned catalogues, read as one class (ai-read.repository.ts:101-148).
public enum InsightProgressionEvent: Sendable, Equatable {
  case recoveryQuest(date: LocalDate, sourceQuest: UUID, state: QuestLogState, isReturnerDay: Bool, completedAtMillis: Int64?, reflectionText: String?)
  case comeback(date: LocalDate, kind: String, xpBonus: Int, coinBonus: Int)
  case returner(date: LocalDate, daysAbsent: Int, shieldPending: Bool)
  case shieldConsumption(date: LocalDate, quest: UUID)
  case achievement(id: String, earnedAtMillis: Int64)
  case title(id: String, earnedAtMillis: Int64)

  var date: LocalDate? {
    switch self {
    case .recoveryQuest(let date, _, _, _, _, _), .comeback(let date, _, _, _), .returner(let date, _, _), .shieldConsumption(let date, _): date
    case .achievement, .title: nil
    }
  }

  var reflectionText: String? {
    guard case .recoveryQuest(_, _, _, _, _, let text) = self else { return nil }
    return text
  }
}

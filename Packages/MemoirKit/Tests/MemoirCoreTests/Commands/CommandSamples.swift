import Foundation
import MemoirCore
import ShadowCore
import ShadowStore

enum CommandSamples {
  static let quest = MemoirStoreFixture.quest
  static let otherQuest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000a2")
  static let metric = MemoirStoreFixture.metric
  static let record = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000c1")
  static let preset = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000e1")

  static func occurrence() throws -> Occurrence {
    Occurrence(quest: quest, date: try MemoirStoreFixture.date("2026-11-19"))
  }

  static func daily() throws -> RecurrenceRule {
    try RecurrenceRule(frequency: .daily, startDate: try MemoirStoreFixture.date("2026-01-01"))
  }

  static func recurrences() throws -> [RecurrenceRule] {
    let start = try MemoirStoreFixture.date("2026-01-01")
    return [
      try daily(),
      try RecurrenceRule(
        frequency: .weekly([.monday, .friday]), interval: 2, startDate: start, end: .count(10),
        exceptions: [try MemoirStoreFixture.date("2026-01-09"), try MemoirStoreFixture.date("2026-01-05")]),
      try RecurrenceRule(frequency: .monthly(.dayOfMonth(31)), startDate: start, end: .until(try MemoirStoreFixture.date("2027-12-31"))),
      try RecurrenceRule(frequency: .monthly(.nthWeekday(.sunday, .last)), startDate: start),
      try RecurrenceRule(frequency: .monthly(.nthWeekday(.tuesday, .second)), interval: 0, startDate: start, end: .count(0)),
      try RecurrenceRule(frequency: .yearly, interval: -3, startDate: start),
    ]
  }

  /// At least one body of every kind, with the variants each kind's payload can take.
  static func all() throws -> [MemoirCommandBody] {
    let occurrence = try occurrence()
    let date = try MemoirStoreFixture.date("2026-11-20")
    var bodies: [MemoirCommandBody] = try recurrences().map { rule in
      .questCreate(
        QuestCreation(questId: quest, schedule: try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 30, statAffinity: .body, recurrence: rule)))
    }
    bodies += [
      .questCreate(
        QuestCreation(
          questId: quest,
          schedule: try QuestSchedule(
            strictness: .anchor, startTimeMinutes: 0, durationMinutes: -5, statAffinity: .mind, optionalStreakOptIn: true, recurrence: try daily(), moduleLink: .weight,
            active: false))),
      .questCreate(QuestCreation(questId: quest, schedule: try QuestSchedule(strictness: .optional, statAffinity: .wealth, recurrence: try daily()))),
      .questUpdate(QuestUpdate(questId: quest, patch: try QuestSchedulePatch())),
      .questUpdate(QuestUpdate(questId: quest, patch: try QuestSchedulePatch(startTimeMinutes: .clear, moduleLink: .clear))),
      .questUpdate(
        QuestUpdate(
          questId: quest,
          patch: try QuestSchedulePatch(
            strictness: .anchor, startTimeMinutes: .set(1439), durationMinutes: 45, statAffinity: .discipline, optionalStreakOptIn: false,
            recurrence: try recurrences()[1], moduleLink: .set(.journal), active: true))),
      .questDelete(QuestReference(questId: quest)),
      .questComplete(occurrence),
      .questPartial(occurrence),
      .questSkip(QuestBreak(occurrence: occurrence)),
      .questSkip(QuestBreak(occurrence: occurrence, reasonTag: .tooTired, hasNote: true)),
      .questPostpone(QuestBreak(occurrence: occurrence, reasonTag: .travel)),
      .questReschedule(try QuestReschedule(occurrence: occurrence, toMinute: 600)),
      .questReschedule(try QuestReschedule(occurrence: occurrence, toMinute: 0, acceptBeyondCap: true, reasonTag: .scheduleConflict, hasNote: true)),
      .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: .health, hasNote: false)),
      .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: nil, hasNote: true)),
      .questEditLog(try QuestLogEdit(occurrence: occurrence)),
      .questEditLog(try QuestLogEdit(occurrence: occurrence, reasonTag: .clear, note: .clear, reflection: .set)),
      .questEditLog(try QuestLogEdit(occurrence: occurrence, reasonTag: .set(.other), note: .set, reflection: .clear)),
      .questDeleteLog(occurrence),
      .recoveryComplete(RecoveryCompletion()),
      .recoveryComplete(RecoveryCompletion(hasReflection: true)),
      .planSetLock(.unlocked),
      .planSetLock(try PlanLock(locking: [otherQuest, quest])),
      .metricCreate(MetricReference(id: metric, metricClass: .general)),
      .metricUpdate(MetricReference(id: metric, metricClass: .health)),
      .metricDelete(MetricDeletion(metric: MetricReference(id: metric, metricClass: .activity), detach: true)),
      .metricRegister(MetricRegistration(metric: MetricReference(id: metric, metricClass: .health), date: date)),
      .metricRegister(MetricRegistration(metric: MetricReference(id: metric, metricClass: .activity), date: date, source: .questLog, questLog: occurrence)),
      .expenseCreate(ExpenseCreation(id: record)),
      .expenseCreate(ExpenseCreation(id: record, source: .ocr)),
      .expenseUpdate(RecordReference(id: record)),
      .expenseDelete(RecordReference(id: record)),
      .subscriptionCreate(RecordReference(id: record)),
      .subscriptionUpdate(RecordReference(id: record)),
      .subscriptionDelete(RecordReference(id: record)),
      .subscriptionConfirmCycle(CycleConfirmation(subscription: record, billingDate: date)),
      .categorySetArchived(try CategoryArchival(categoryId: try MemoirStoreFixture.category("food"), archived: true)),
      .categorySetArchived(try CategoryArchival(categoryId: try MemoirStoreFixture.category("subs"), archived: false)),
      .titleDisplay(TitleDisplay(title: .steadyBuilder)),
      .titleDisplay(TitleDisplay(title: nil)),
      .cosmeticPurchase(.badgeBronze),
      .cosmeticEquip(.themeReturner),
      .journalSave(QuickLogEntry(id: record, date: date)),
      .mealLog(QuickLogEntry(id: record, date: date)),
      .mealLogPreset(PresetMealEntry(id: record, presetId: preset, date: date)),
      .mealSavePreset(RecordReference(id: preset)),
      .mealPresetUpdate(RecordReference(id: preset)),
      .mealPresetDelete(RecordReference(id: preset)),
      .weightSave(WeightEntry(date: date)),
      .weightSave(WeightEntry(date: date, confirmedReplacement: true)),
      .sideQuestLog(SideQuestEntry(id: record, date: date)),
      .sideQuestLog(SideQuestEntry(id: record, date: date, statAffinity: .body)),
      .accountSetTimeZone(try TimeZoneChange(identifier: "America/Argentina/Buenos_Aires")),
      .accountSetTimeZone(try TimeZoneChange(identifier: "Etc/GMT+5")),
      .accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)),
      .accountSetReturnerThreshold(try ReturnerThresholdChange(days: 90)),
      .receiptScan(ReceiptScan()),
      .receiptScan(ReceiptScan(receiptId: record)),
    ]
    return bodies
  }

  static func text(for body: MemoirCommandBody) -> String? {
    switch body.textSlot {
    case .reasonNote?: "Physio said rest this week"
    case .reflection?: "Rested and ready again"
    case nil: nil
    }
  }
}

extension JSONValue {
  /// Every leaf with its path in the style of `CommandPayload.integerPaths`: dotted keys, `[]` for an array element.
  func leaves(at pattern: String = "") -> [(pattern: String, value: JSONValue)] {
    switch self {
    case .object(let members):
      members.sorted { $0.key < $1.key }.flatMap { key, value in value.leaves(at: pattern.isEmpty ? key : "\(pattern).\(key)") }
    case .array(let elements):
      elements.flatMap { $0.leaves(at: "\(pattern)[]") }
    default:
      [(pattern, self)]
    }
  }

  /// A copy with `transform` applied at every node; `path` names array elements by index.
  func editions(_ transform: (_ path: [PathStep], _ node: JSONValue) -> [JSONValue], path: [PathStep] = []) -> [JSONValue] {
    var results = transform(path, self)
    switch self {
    case .object(let members):
      for (key, value) in members.sorted(by: { $0.key < $1.key }) {
        for edited in value.editions(transform, path: path + [.key(key)]) {
          var copy = members
          copy[key] = edited
          results.append(.object(copy))
        }
      }
    case .array(let elements):
      for (index, value) in elements.enumerated() {
        for edited in value.editions(transform, path: path + [.index(index)]) {
          var copy = elements
          copy[index] = edited
          results.append(.array(copy))
        }
      }
    default:
      break
    }
    return results
  }
}

enum PathStep: Hashable {
  case key(String)
  case index(Int)
}

extension [PathStep] {
  var pattern: String {
    reduce(into: "") { pattern, step in
      switch step {
      case .key(let key): pattern = pattern.isEmpty ? key : "\(pattern).\(key)"
      case .index: pattern += "[]"
      }
    }
  }
}

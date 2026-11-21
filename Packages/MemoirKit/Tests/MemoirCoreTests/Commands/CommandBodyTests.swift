import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir command bodies", TestTimeLimit.quick)
struct CommandBodyTests {
  private static let contentKeys: Set<String> = [
    "name", "notes", "text", "kg", "value", "calories", "amountMinor", "amountText", "merchant", "mood", "tags", "unit", "glyph", "extractedText", "notification",
  ]
  private static let textsShapedAsTokens: [JSONValue] = ["Morning_run", "felt-off-today", "72kg", "felt off today"]
  private static let closedTokens: Set<String> = {
    var tokens: Set<String> = ["daily", "weekly", "monthly", "yearly", "never", "count", "until", "day_of_month", "nth_weekday", "last"]
    func add<Value: RawRepresentable<String> & CaseIterable>(_ type: Value.Type) { tokens.formUnion(type.allCases.map(\.rawValue)) }
    add(Strictness.self)
    add(StatAffinity.self)
    add(ReasonTag.self)
    add(IntensityMode.self)
    add(TitleID.self)
    add(CosmeticID.self)
    add(SyncClass.self)
    add(MetricEntrySource.self)
    add(ExpenseSource.self)
    add(QuestModuleLink.self)
    return tokens
  }()

  private func decode(_ body: MemoirCommandBody, payload members: [String: JSONValue]) throws(CommandRefusal) -> MemoirCommandBody {
    try MemoirCommandBody(type: body.kind.commandType, payload: members, occurrence: body.occurrence)
  }

  @Test func shouldCoverEveryCommandTypeOfTheReference() throws {
    #expect(MemoirCommandKind.allCases.count == 40)
    #expect(Set(try CommandSamples.all().map(\.kind)) == Set(MemoirCommandKind.allCases))
    for kind in MemoirCommandKind.allCases { #expect(MemoirCommandKind(kind.commandType) == kind) }
  }

  @Test func shouldRoundTripEveryBodyThroughItsPayload() throws {
    for body in try CommandSamples.all() {
      let payload = try body.payload()
      #expect(payload.type == body.kind.commandType)
      #expect(try decode(body, payload: payload.members) == body, "\(body.kind.rawValue)")
      #expect(try body.payload() == payload)
    }
  }

  @Test func shouldCarryOnlyIdsDatesTokensFlagsAndPinnedIntegers() throws {
    for body in try CommandSamples.all() {
      let payload = try body.payload()
      for (pattern, value) in JSONValue.object(payload.members).leaves() {
        let key = pattern.split(separator: ".").last.map(String.init) ?? pattern
        #expect(!Self.contentKeys.contains(key.replacing("[]", with: "")), "\(body.kind.rawValue) \(pattern)")
        #expect(!CommandPayload.measurementKeys.contains(key), "\(body.kind.rawValue) \(pattern)")
        switch value {
        case .null, .bool: continue
        case .int: #expect(body.kind.integerPaths.contains(pattern), "\(body.kind.rawValue) \(pattern)")
        case .string(let text): #expect(isNamedValue(text, at: pattern), "\(body.kind.rawValue) \(pattern) = \(text)")
        case .array, .object: Issue.record("leaves are scalars")
        }
      }
    }
  }

  private func isNamedValue(_ text: String, at pattern: String) -> Bool {
    if UUID(stored: .string(text)) != nil || LocalDate(isoString: text) != nil || Self.closedTokens.contains(text) { return true }
    switch pattern {
    case "categoryId": return CategoryArchival.builtInCategories.contains(text)
    case "timezone": return TimeZone(identifier: text) != nil
    default: return false
    }
  }

  @Test func shouldRefuseFreeTextOrAMeasurementAnywhereInAnyPayload() throws {
    for body in try CommandSamples.all() {
      let root = JSONValue.object(try body.payload().members)
      let injected = root.editions { path, node in
        switch node {
        case .object(let members):
          ["value", "weight", "steps", "comment", "reason"].flatMap { key -> [JSONValue] in
            [72, "Morning run", "Morning_run", "8042", "72kg"].map { injected in .object(members.merging([key: injected]) { $1 }) }
          }
        case .array(let elements):
          [.array(elements + ["Morning run"]), .array(elements + ["Morning_run"]), .array(elements + [72])]
        case .string:
          path.pattern == "timezone"
            ? Self.textsShapedAsTokens + ["GMT+5", "europe/berlin", "+05:00"] : Self.textsShapedAsTokens + ["Morning run", "72.5", "8042", "Saw/The_doctor"]
        case .int:
          path.pattern == "toMin" || path.pattern.hasSuffix("startTimeMinutes") ? [.int(7215)] : ["7215"]
        case .bool, .null:
          body.kind.integerPaths.contains(path.pattern) ? [] : [72, "Morning run", "Morning_run"]
        }
      }
      #expect(!injected.isEmpty)
      for edited in injected {
        guard let members = edited.objectValue, members != root.objectValue else { continue }
        #expect(throws: CommandRefusal.self, "\(body.kind.rawValue) \(CanonicalJSON.encode(edited).count)") { try decode(body, payload: members) }
      }
    }
  }

  @Test func shouldPinEachIntegerToItsTypesPaths() throws {
    let recurrence: Set<String> = ["interval", "end.count", "daysOfWeek[]", "pattern.dayOfMonth", "pattern.weekday", "pattern.ordinal"]
    let schedule = Set(["startTimeMinutes", "durationMinutes"] + recurrence.map { "recurrence.\($0)" })
    let expected: [MemoirCommandKind: Set<String>] = [
      .questCreate: schedule, .questUpdate: Set(schedule.map { "patch.\($0)" }), .questReschedule: ["toMin"], .accountSetReturnerThreshold: ["returnerThresholdDays"],
    ]
    let every = Set(MemoirCommandKind.allCases.flatMap(\.integerPaths)).union(["count", "durationMinutes", "value", "steps"])
    for kind in MemoirCommandKind.allCases {
      #expect(kind.integerPaths == expected[kind, default: []], "\(kind.rawValue)")
      #expect(CommandPayload.integerPaths(for: kind.commandType) == kind.integerPaths)
      for pattern in every {
        let members = try #require(Self.nested(pattern, holding: 3).objectValue)
        if kind.integerPaths.contains(pattern) {
          #expect(try CommandPayload(members, type: kind.commandType).members == members)
        } else {
          #expect(throws: MemoirCommandError.self, "\(kind.rawValue) \(pattern)") { try CommandPayload(members, type: kind.commandType) }
        }
      }
    }
    let unknown = try CommandType("quest.fly")
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.count")) { try CommandPayload(["count": 3], type: unknown) }
  }

  private static func nested(_ pattern: String, holding value: JSONValue) -> JSONValue {
    guard let dot = pattern.firstIndex(of: ".") else {
      return pattern.hasSuffix("[]") ? .object([String(pattern.dropLast(2)): [value]]) : .object([pattern: value])
    }
    let head = String(pattern[..<dot])
    let rest = nested(String(pattern[pattern.index(after: dot)...]), holding: value)
    return head.hasSuffix("[]") ? .object([String(head.dropLast(2)): [rest]]) : .object([head: rest])
  }

  @Test func shouldRefuseAnOccurrenceWhereTheKindDoesNotTakeOne() throws {
    let occurrence = try CommandSamples.occurrence()
    #expect(throws: CommandRefusal.occurrenceRequired(.questComplete)) {
      try MemoirCommandBody(type: MemoirCommandKind.questComplete.commandType, payload: [:], occurrence: nil)
    }
    #expect(throws: CommandRefusal.occurrenceUnexpected(.questCreate)) {
      try MemoirCommandBody(type: MemoirCommandKind.questCreate.commandType, payload: [:], occurrence: occurrence)
    }
    let registration = try MemoirCommandBody(
      type: MemoirCommandKind.metricRegister.commandType, payload: ["metricId": .string(CommandSamples.metric.lowercasedString), "metricClass": "health", "date": "2026-11-19"],
      occurrence: nil)
    #expect(registration.occurrence == nil)
    #expect(throws: CommandRefusal.unknownType("quest.fly")) { try MemoirCommandBody(type: try CommandType("quest.fly"), payload: [:], occurrence: nil) }
  }

  @Test func shouldRefuseTypedValuesTheReferenceRefusesAndTheNativeRefusals() throws {
    let occurrence = try CommandSamples.occurrence()
    let daily = try CommandSamples.daily()
    #expect(throws: CommandRefusal.anchorNeedsStartTime) { try QuestSchedule(strictness: .anchor, statAffinity: .body, recurrence: daily) }
    #expect(throws: CommandRefusal.invalidField(field: "startTimeMinutes", problem: .outOfRange)) {
      try QuestSchedule(strictness: .routine, startTimeMinutes: 1440, statAffinity: .body, recurrence: daily)
    }
    #expect(throws: CommandRefusal.anchorNeedsStartTime) { try QuestSchedulePatch(strictness: .anchor, startTimeMinutes: .clear) }
    #expect(throws: CommandRefusal.invalidField(field: "startTimeMinutes", problem: .outOfRange)) { try QuestSchedulePatch(startTimeMinutes: .set(-1)) }
    #expect(try QuestSchedulePatch(strictness: .anchor).strictness == .anchor)
    #expect(throws: CommandRefusal.invalidField(field: "toMin", problem: .outOfRange)) { try QuestReschedule(occurrence: occurrence, toMinute: 1440) }
    #expect(throws: CommandRefusal.invalidField(field: "reasonTag", problem: .required)) { try QuestReason(occurrence: occurrence, reasonTag: nil, hasNote: false) }
    #expect(throws: CommandRefusal.oneTextPerCommand) { try QuestLogEdit(occurrence: occurrence, note: .set, reflection: .set) }
    #expect(throws: CommandRefusal.invalidField(field: "questIds", problem: .required)) { try PlanLock(locking: []) }
    #expect(throws: CommandRefusal.duplicateLockedQuest) { try PlanLock(locking: [CommandSamples.quest, CommandSamples.quest]) }
    for key in ["uncat", "subs"] {
      let category = try MemoirStoreFixture.category(key)
      #expect(throws: CommandRefusal.categoryNotArchivable(category)) { try CategoryArchival(categoryId: category, archived: true) }
      #expect(try CategoryArchival(categoryId: category, archived: false).archived == false)
    }
    #expect(throws: CommandRefusal.invalidField(field: "returnerThresholdDays", problem: .outOfRange)) { try ReturnerThresholdChange(days: 0) }
    #expect(throws: CommandRefusal.invalidField(field: "returnerThresholdDays", problem: .outOfRange)) { try ReturnerThresholdChange(days: 91) }
    for identifier in [
      "Mars/Olympus", "", "12345", "Europe/Berlin\n", String(repeating: "A", count: 65), "GMT+5", "GMT+0530", "UTC+3", "europe/berlin", "+05:00", "CET", "Japan",
      "Morning_run", "Europe/", "/Berlin", "Europe//Berlin",
    ] {
      #expect(throws: CommandRefusal.invalidField(field: "timezone", problem: .notAllowed), "\(identifier)") { try TimeZoneChange(identifier: identifier) }
    }
    for identifier in ["UTC", "GMT", "Etc/GMT+5", "Etc/GMT-14", "Europe/Berlin", "America/Port-au-Prince", "America/Argentina/Buenos_Aires"] {
      #expect(try TimeZoneChange(identifier: identifier).identifier == identifier)
    }
    for key in ["rent", "groceries2"] {
      #expect(throws: CommandRefusal.unknownCategory(key)) { try CategoryArchival(categoryId: try MemoirStoreFixture.category(key), archived: false) }
    }
    #expect(CosmeticID.allCases.filter { $0.priceCoins == nil } == CosmeticID.allCases.filter { $0.unlockedBy != nil })
  }

  @Test func shouldRefuseTheCalendarsNativeRefusalsBeforeTheyBecomeCommands() throws {
    let base: [String: JSONValue] = [
      "questId": .string(CommandSamples.quest.lowercasedString), "strictness": "routine", "statAffinity": "body",
      "recurrence": ["frequency": "monthly", "startDate": "2026-01-01", "end": ["kind": "never"], "pattern": ["kind": "day_of_month", "dayOfMonth": 0]],
    ]
    #expect(throws: CommandRefusal.calendar(field: "recurrence.pattern.dayOfMonth", .dayOfMonthOutOfRange(0))) {
      try MemoirCommandBody(type: MemoirCommandKind.questCreate.commandType, payload: base, occurrence: nil)
    }
    var weekly = base
    weekly["recurrence"] = ["frequency": "weekly", "startDate": "2026-01-01", "end": ["kind": "never"], "daysOfWeek": []]
    #expect(throws: CommandRefusal.invalidField(field: "recurrence.daysOfWeek", problem: .required)) {
      try MemoirCommandBody(type: MemoirCommandKind.questCreate.commandType, payload: weekly, occurrence: nil)
    }
    var minute = base
    minute["recurrence"] = ["frequency": "daily", "startDate": "2026-01-01", "end": ["kind": "never"]]
    minute["startTimeMinutes"] = 1440
    #expect(throws: CommandRefusal.invalidField(field: "startTimeMinutes", problem: .outOfRange)) {
      try MemoirCommandBody(type: MemoirCommandKind.questCreate.commandType, payload: minute, occurrence: nil)
    }
    let subscription = SubscriptionRecord(
      id: CommandSamples.record, name: "Music", amountMinor: 999, currency: try MemoirStoreFixture.currency("EUR"), frequency: .known(.monthly), billingDay: 32,
      anchorOn: try MemoirStoreFixture.date("2026-12-05"), category: try MemoirStoreFixture.category("subs"))
    #expect(throws: CommandRefusal.calendar(field: "billingDay", .billingDayOutOfRange(32))) { try subscription.validate() }
    var custom = subscription
    custom.billingDay = 5
    custom.frequency = .known(.custom)
    custom.customIntervalDays = 0
    #expect(throws: CommandRefusal.invalidField(field: "customIntervalDays", problem: .outOfRange)) { try custom.validate() }
    custom.customIntervalDays = 14
    try custom.validate()
    custom.frequency = .unknown("fortnightly")
    #expect(throws: CommandRefusal.invalidField(field: "frequency", problem: .notAllowed)) { try custom.validate() }
  }

  @Test func shouldDecodeAZoneThisDeviceDoesNotKnowButRefuseToIssueIt() throws {
    let body = try MemoirCommandBody(type: MemoirCommandKind.accountSetTimeZone.commandType, payload: ["timezone": "Mars/Olympus"], occurrence: nil)
    guard case .accountSetTimeZone(let change) = body else { throw MemoirFixtureError(description: "expected a time-zone change, got \(body)") }
    #expect(change.identifier == "Mars/Olympus")
    #expect(throws: CommandRefusal.self) { try TimeZoneChange(identifier: change.identifier) }
    for identifier in ["Morning_run", "felt-off-today", "72kg", "GMT+5", "GMT+0530", "UTC+3", "europe/berlin", "CET"] {
      #expect(throws: CommandRefusal.invalidField(field: "timezone", problem: .notAllowed), "\(identifier)") {
        try MemoirCommandBody(type: MemoirCommandKind.accountSetTimeZone.commandType, payload: ["timezone": .string(identifier)], occurrence: nil)
      }
    }
  }

  @Test func shouldStageTheZoneAndIntensityButApplyTheThresholdAndFirstZoneAtOnce() throws {
    #expect(MemoirCommandKind.accountSetTimeZone.settingTiming == .staged)
    #expect(MemoirCommandKind.accountSetIntensityMode.settingTiming == .staged)
    #expect(MemoirCommandKind.accountSetReturnerThreshold.settingTiming == .immediate)
    #expect(MemoirCommandKind.allCases.filter { $0.settingTiming != nil }.count == 3)
    #expect(SettingTiming.staged.isStaged(replacingValueInForce: true))
    #expect(!SettingTiming.staged.isStaged(replacingValueInForce: false), "with no value in force a staged setting applies at once")
    #expect(!SettingTiming.immediate.isStaged(replacingValueInForce: true))
  }
}

import Foundation
import MemoirCore
import ShadowCore
import Testing

/// `Fixtures/commands/`: the reference's verdict on each payload, and the native one where the case records a deliberate difference.
@Suite("Memoir command vectors", TestTimeLimit.quick)
struct CommandVectorTests {
  private enum Verdict: CustomStringConvertible {
    case accepted
    case refused(field: String?, code: String?)
    case crashed

    init(_ json: JSONValue) throws {
      guard let members = json.objectValue else { throw FixtureError.malformed("verdict \(json)") }
      if members["accepted"] != nil {
        self = .accepted
      } else if let refused = members["refused"]?.objectValue {
        self = .refused(field: refused["field"]?.stringValue, code: refused["code"]?.stringValue)
      } else if members["crashed"] != nil {
        self = .crashed
      } else {
        throw FixtureError.malformed("verdict \(json)")
      }
    }

    var description: String {
      switch self {
      case .accepted: "accepted"
      case .refused(let field, let code): "refused \(field ?? code ?? "?")"
      case .crashed: "crashed"
      }
    }
  }

  private struct Case {
    let id: String
    let payload: [String: JSONValue]
    let occurrence: Occurrence?
    let content: [String: JSONValue]
    let expected: Verdict
    let differsFromReference: Bool

    init(_ json: JSONValue) throws {
      guard let members = json.objectValue, let id = members["id"]?.stringValue, let payload = members["payload"]?.objectValue else {
        throw FixtureError.malformed("case \(json)")
      }
      self.id = id
      self.payload = payload
      content = members["content"]?.objectValue ?? [:]
      if let occurrence = members["occurrence"]?.objectValue {
        guard let quest = occurrence["quest"].flatMap(UUID.init(stored:)), let date = occurrence["date"].flatMap(LocalDate.init(stored:)) else {
          throw FixtureError.malformed("occurrence of \(id)")
        }
        self.occurrence = Occurrence(quest: quest, date: date)
      } else {
        occurrence = nil
      }
      let native = Self.present(members["native"])
      differsFromReference = native != nil
      guard let verdict = native ?? Self.present(members["reference"]) else { throw FixtureError.malformed("\(id) has no verdict") }
      if native != nil, members["reason"]?.stringValue?.isEmpty ?? true { throw FixtureError.malformed("\(id) differs from the reference without a reason") }
      expected = try Verdict(verdict)
    }

    private static func present(_ value: JSONValue?) -> JSONValue? {
      guard let value, !value.isNull else { return nil }
      return value
    }
  }

  private static func load(_ file: String) throws -> JSONValue {
    try CanonicalJSON.decode(try MemoirStoreFixture.fixture("commands/\(file)"), mode: .lenient)
  }

  private func check(_ outcome: Result<Void, CommandRefusal>, _ expected: Verdict, _ label: String) {
    switch (expected, outcome) {
    case (.accepted, .success), (.crashed, .failure):
      return
    case (.refused(let field, let code), .failure(let refusal)):
      if let field { #expect(refusal.field == field, "\(label): \(refusal)") }
      if let code { #expect(refusal.referenceCode == code || refusal.code == code, "\(label): \(refusal)") }
    case (_, .success):
      Issue.record("\(label): expected \(expected), but it was accepted")
    case (.accepted, .failure(let refusal)):
      Issue.record("\(label): expected acceptance, got \(refusal)")
    }
  }

  @Test func shouldDecodeEveryPayloadAsTheReferenceJudgesIt() throws {
    let groups = try #require(try Self.load("commands.json").objectValue)
    var kinds = Set<MemoirCommandKind>()
    var count = 0
    for (type, cases) in groups.sorted(by: { $0.key < $1.key }) {
      let commandType = try CommandType(type)
      if let kind = MemoirCommandKind(commandType) { kinds.insert(kind) }
      for json in try #require(cases.arrayValue) {
        let item = try Case(json)
        count += 1
        let outcome = Result<Void, CommandRefusal> { () throws(CommandRefusal) in
          let body = try MemoirCommandBody(type: commandType, payload: item.payload, occurrence: item.occurrence)
          let again = try MemoirCommandBody(type: commandType, payload: try body.payload().members, occurrence: body.occurrence)
          #expect(again == body, "\(type)/\(item.id) round trip")
        }
        check(outcome, item.expected, "\(type)/\(item.id)")
      }
    }
    #expect(kinds == Set(MemoirCommandKind.allCases))
    #expect(count >= 280)
  }

  @Test func shouldValidateTheContentACommandNamesAsTheReferenceDoes() throws {
    let cases = try #require(try Self.load("content.json").arrayValue)
    #expect(cases.count >= 25)
    for json in cases {
      let item = try Case(json)
      let type = try #require(json.objectValue?["type"]?.stringValue)
      let outcome = Result<Void, CommandRefusal> { () throws(CommandRefusal) in try validate(type, item) }
      check(outcome, item.expected, "content \(item.id)")
    }
  }

  private func validate(_ type: String, _ item: Case) throws(CommandRefusal) {
    let content = item.content
    let date = LocalDate(isoString: "2026-11-20") ?? .earliest
    func text(_ key: String, _ fallback: String) -> String { content[key]?.stringValue ?? fallback }
    func number(_ key: String, _ fallback: Int) -> Int { content[key]?.intValue.map { Int($0) } ?? fallback }
    switch type {
    case "quest.create":
      try QuestRecord(id: CommandSamples.quest, name: text("name", "Morning run")).validate()
    case "quest.skip", "quest.reschedule", "quest.attachReason", "recovery.complete":
      let slot = content["note"] != nil ? "note" : "reflectionText"
      let body = try MemoirCommandBody(
        type: try commandType(type), payload: item.payload.merging([slot: true]) { $1 }, occurrence: item.occurrence)
      try CommandIssuer.validate(text: text(slot, ""), for: body)
    case "journal.save":
      try JournalEntryRecord(id: CommandSamples.record, date: date, text: text("text", "A good day"), mood: content["mood"]?.intValue.map { Int($0) }, loggedAtMillis: 0)
        .validate()
    case "meal.log":
      try MealRecord(id: CommandSamples.record, date: date, name: text("name", "Oats"), calories: number("calories", 300), mealType: .known(.cooked), loggedAtMillis: 0)
        .validate()
    case "meal.savePreset":
      try MealPresetRecord(id: CommandSamples.preset, name: text("name", "Oats"), calories: number("calories", 300), mealType: .known(.cooked)).validate()
    case "sidequest.log":
      try SideQuestRecord(id: CommandSamples.record, date: date, name: text("name", "Helped a neighbour"), loggedAtMillis: 0).validate()
    case "weight.save":
      guard let kilograms = DecimalText(text("kg", "72.5")) else { throw .invalidField(field: "kg", problem: .notAllowed) }
      try WeightRecord(date: date, kilograms: kilograms, loggedAtMillis: 0).validate()
    case "metric.create":
      try MetricRecord<GeneralMetric>(id: MetricID(recordUUID: CommandSamples.metric), name: text("name", "Steps"), valueType: .known(.count), direction: .known(.higher))
        .validate()
    case "subscription.create":
      guard let currency = CurrencyCode("EUR"), let category = CategoryKey("subs") else { throw .invalidField(field: "currency", problem: .notAllowed) }
      try SubscriptionRecord(
        id: CommandSamples.record, name: text("name", "Music"), amountMinor: 999, currency: currency, frequency: .known(.monthly), billingDay: number("billingDay", 5),
        anchorOn: date, category: category
      ).validate()
    default:
      Issue.record("no content check for \(type)")
    }
  }

  private func commandType(_ name: String) throws(CommandRefusal) -> CommandType {
    do throws(MemoirCommandError) {
      return try CommandType(name)
    } catch {
      throw .payload(error)
    }
  }
}

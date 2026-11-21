import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Testing

@Suite("Memoir command issuing", TestTimeLimit.standard)
struct CommandIssuerTests {
  /// 2026-11-20 23:30 UTC: already 00:30 on the 21st in Berlin (UTC+1), still the 20th in New York.
  private static let instant: Int64 = 1_795_217_400_000

  private func issuer(_ zone: String, at instant: Int64 = instant) throws -> CommandIssuer {
    let clock = IssueClock(timeZone: try #require(TimeZone(identifier: zone)))
    return CommandIssuer(clock: clock) { Date(timeIntervalSince1970: TimeInterval(instant) / 1000) }
  }

  @Test func shouldStampTheInstantOffsetZoneDayAndRulesetVersion() throws {
    let body = MemoirCommandBody.questComplete(try CommandSamples.occurrence())
    let berlin = try issuer("Europe/Berlin").command(body)
    #expect(berlin.instantMillis == Self.instant)
    #expect(berlin.utcOffsetMinutes == 60)
    #expect(berlin.issuedOn == (try MemoirStoreFixture.date("2026-11-21")))
    #expect(berlin.rulesetVersion == Ruleset.current.version)
    #expect(berlin.type == MemoirCommandKind.questComplete.commandType)
    #expect(berlin.occurrence == body.occurrence)
    #expect(try MemoirCommandBody(berlin) == body)
    let timestamp = try #require(berlin.id.v7Timestamp)
    #expect(abs(timestamp.timeIntervalSince1970 * 1000 - Double(Self.instant)) < 1)
    let newYork = try issuer("America/New_York").command(body)
    #expect(newYork.utcOffsetMinutes == -300)
    #expect(newYork.issuedOn == (try MemoirStoreFixture.date("2026-11-20")))
    #expect(newYork.id != berlin.id)
  }

  @Test func shouldDateACommandByTheZonesDayEvenWhenTheOpenDayRunsAhead() throws {
    let change = MemoirCommandBody.accountSetIntensityMode(IntensityModeChange(mode: .highIntensity))
    let command = try issuer("America/New_York").command(change)
    #expect(command.issuedOn == (try MemoirStoreFixture.date("2026-11-20")))
    #expect(command.issuedOn == (try IssueClock(timeZone: try #require(TimeZone(identifier: "America/New_York"))).stamp(at: Self.instant).issuedOn))
    #expect(change.kind.settingTiming == .staged)
  }

  @Test func shouldIssueEveryKindIntoTheStoreAndReadItBack() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let issuer = try issuer("Asia/Kathmandu")
    let bodies = try CommandSamples.all()
    let issued = try await store.write { transaction in
      try bodies.map { body in try issuer.issue(body, text: CommandSamples.text(for: body), in: &transaction) }
    }
    let listing = try await store.read { transaction in try MemoirCommand.listing(in: transaction) }
    #expect(listing.unreadable == 0)
    #expect(Set(listing.entries.map(\.record.id)) == Set(issued.map(\.id)))
    for command in issued {
      let stored = try #require(listing.entries.first { $0.record.id == command.id }?.record)
      #expect(stored == command)
      let body = try MemoirCommandBody(stored)
      #expect(bodies.contains(body))
      let note = try await store.read { transaction in try CommandNoteRecord.read(id: command.id, in: transaction) }
      #expect(note.entry?.record.text == CommandSamples.text(for: body), "\(body.kind.rawValue)")
    }
  }

  @Test func shouldRefuseATextThatDoesNotFitTheBodysSlot() throws {
    let occurrence = try CommandSamples.occurrence()
    let skip = MemoirCommandBody.questSkip(QuestBreak(occurrence: occurrence, hasNote: true))
    let complete = MemoirCommandBody.questComplete(occurrence)
    let reflection = MemoirCommandBody.recoveryComplete(RecoveryCompletion(hasReflection: true))
    #expect(throws: CommandRefusal.textRequired(field: "note")) { try CommandIssuer.validate(text: nil, for: skip) }
    #expect(throws: CommandRefusal.textRequired(field: "reflectionText")) { try CommandIssuer.validate(text: nil, for: reflection) }
    #expect(throws: CommandRefusal.textUnexpected) { try CommandIssuer.validate(text: "Felt off", for: complete) }
    #expect(throws: CommandRefusal.invalidField(field: "note", problem: .required)) { try CommandIssuer.validate(text: "", for: skip) }
    #expect(throws: CommandRefusal.invalidField(field: "note", problem: .tooLong)) { try CommandIssuer.validate(text: String(repeating: "n", count: 121), for: skip) }
    #expect(throws: CommandRefusal.invalidField(field: "note", problem: .tooLong)) {
      try CommandIssuer.validate(text: String(repeating: "n", count: 119) + "\u{1F600}", for: skip)
    }
    try CommandIssuer.validate(text: String(repeating: "n", count: 118) + "\u{1F600}", for: skip)
    try CommandIssuer.validate(text: String(repeating: "é", count: 120), for: skip)
    try CommandIssuer.validate(text: nil, for: complete)
    #expect(throws: CommandRefusal.invalidField(field: "reflectionText", problem: .empty)) { try CommandIssuer.validate(text: "", for: reflection) }
    try CommandIssuer.validate(text: String(repeating: "r", count: 500), for: reflection)
  }

  @Test func shouldWriteNothingWhenIssuingIsRefused() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let issuer = try issuer("UTC")
    let skip = MemoirCommandBody.questSkip(QuestBreak(occurrence: try CommandSamples.occurrence(), hasNote: true))
    let refusal = try await store.write { transaction -> CommandIssueError? in
      do throws(CommandIssueError) {
        try issuer.issue(skip, text: String(repeating: "n", count: 121), in: &transaction)
        return nil
      } catch {
        return error
      }
    }
    guard case .refused(.invalidField(field: "note", problem: .tooLong))? = refusal else {
      throw MemoirFixtureError(description: "expected a refusal, got \(String(describing: refusal))")
    }
    #expect(try await store.pendingChanges(limit: 10).isEmpty)
  }

  @Test func shouldRefuseAnInstantOutsideTheCalendar() throws {
    let issuer = CommandIssuer(clock: IssueClock(timeZone: .gmt)) { Date(timeIntervalSince1970: 400_000_000_000) }
    #expect(throws: CommandIssueError.self) { try issuer.command(.receiptScan(ReceiptScan())) }
  }

  @Test func shouldValidateTheNamedContentBeforeAppendingTheCommand() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let issuer = try issuer("UTC")
    let date = try MemoirStoreFixture.date("2026-11-20")
    let body = MemoirCommandBody.mealLog(QuickLogEntry(id: CommandSamples.record, date: date))
    let meal = MealRecord(id: CommandSamples.record, date: date, name: "Oats", calories: -1, mealType: .known(.cooked), loggedAtMillis: Self.instant)
    let refusal = try await store.write { transaction -> CommandIssueError? in
      do throws(CommandIssueError) {
        try issuer.issue(body, content: meal, in: &transaction)
        return nil
      } catch {
        return error
      }
    }
    guard case .refused(.invalidField(field: "calories", problem: .outOfRange))? = refusal else { throw MemoirFixtureError(description: "got \(String(describing: refusal))") }
    #expect(try await store.pendingChanges(limit: 10).isEmpty)
    let valid = MealRecord(id: CommandSamples.record, date: date, name: "Oats", calories: 300, mealType: .known(.cooked), loggedAtMillis: Self.instant)
    let command = try await store.write { transaction in
      _ = try valid.create(in: &transaction)
      return try issuer.issue(body, content: valid, in: &transaction)
    }
    #expect(try MemoirCommandBody(command) == body)
  }

  @Test func shouldConfirmACycleWithItsExpenseInOneWrite() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let issuer = try issuer("UTC")
    let subscription = SubscriptionRecord(
      id: CommandSamples.record, name: "Music", amountMinor: 999, currency: try MemoirStoreFixture.currency("EUR"), frequency: .known(.monthly), billingDay: 5,
      anchorOn: try MemoirStoreFixture.date("2026-11-05"), category: try MemoirStoreFixture.category("subs"))
    let confirmation = CycleConfirmation(subscription: subscription.id, billingDate: try MemoirStoreFixture.date("2026-11-05"))
    let missing = try await store.write { transaction -> CommandIssueError? in
      do throws(CommandIssueError) {
        try issuer.confirmCycle(confirmation, in: &transaction)
        return nil
      } catch {
        return error
      }
    }
    guard case .finance(.subscriptionAbsent(subscription.id))? = missing else { throw MemoirFixtureError(description: "got \(String(describing: missing))") }
    #expect(try await store.pendingChanges(limit: 10).isEmpty)
    _ = try await store.write { transaction in try subscription.create(in: &transaction) }
    let (command, expense) = try await store.write { transaction in try issuer.confirmCycle(confirmation, in: &transaction) }
    #expect(try MemoirCommandBody(command) == .subscriptionConfirmCycle(confirmation))
    let written = try #require(expense)
    #expect(written.id == SubscriptionCycles.expenseID(for: confirmation))
    #expect(written.loggedAtMillis == command.instantMillis)
    #expect(written.occurredOn == confirmation.billingDate)
    let again = try await store.write { transaction in try issuer.confirmCycle(confirmation, in: &transaction) }
    #expect(again.expense == nil)
    #expect(try await store.read { transaction in try MemoirCommand.listing(in: transaction) }.entries.count == 2)
  }
}

import Foundation
import MemoirCore
import ShadowStore
import Testing

@testable import Memoir

@Suite("MemoirWriter", TestTimeLimit.standard)
struct MemoirWriterTests {
  private struct Abandoned: Error {}

  private static func open(_ clock: TestClock, deviceZone: TimeZone = TestClock.berlin) async throws -> MemoirScreenContext {
    MemoirScreenContext(try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock.memoir(deviceZone: deviceZone)))
  }

  @Test("should stamp with the device's zone before any zone is set, at the trusted clock's instant")
  func stampsWithTheDeviceZoneFirst() async throws {
    let clock = TestClock(day: 0, minute: 23 * 60 + 30)
    let context = try await Self.open(clock)

    let command = try await context.writer.issue(try TestQuests.zone("UTC"))

    #expect(command.instantMillis == TestClock.millis(day: 0, minute: 23 * 60 + 30))
    #expect(command.utcOffsetMinutes == 60)
    #expect(command.issuedOn == TestClock.day(1), "half past midnight in Berlin")
    #expect(try await context.stores.commands() == [command])
  }

  @Test("should stamp with the zone in force until the account's day has passed, and with the staged zone after")
  func stampsWithTheAccountZone() async throws {
    let clock = TestClock(day: 0, minute: 720)
    let context = try await Self.open(clock)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    let staging = try await context.writer.issue(try TestQuests.zone("Asia/Tokyo"))
    #expect(staging.utcOffsetMinutes == 0, "UTC is in force once set")
    #expect(try await context.today() == MemoirToday(date: TestClock.day(0), source: .account("UTC")))

    clock.set(day: 0, minute: 23 * 60 + 30)
    let late = try await context.writer.issue(try TestQuests.creation(UUID()))
    #expect(late.utcOffsetMinutes == 0 && late.issuedOn == TestClock.day(0), "Berlin and Tokyo are already on the next day; the account is not")

    clock.set(day: 1, minute: 30)
    let staged = try await context.writer.issue(try TestQuests.creation(UUID()))
    #expect(staged.utcOffsetMinutes == 540 && staged.issuedOn == TestClock.day(1))
    #expect(staged.instantMillis == TestClock.millis(day: 1, minute: 30))
    #expect(try await context.today().date == TestClock.day(1))
  }

  @Test("should stamp the core writers' commands with the zone as each is written, even after a staged zone takes over")
  func stampsCoreWritersAsWritten() async throws {
    let clock = TestClock(day: 0, minute: 720)
    let context = try await Self.open(clock)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    try await context.writer.issue(try TestQuests.zone("Asia/Tokyo"))
    let quickLogs = context.writer.quickLogs
    let metrics = context.writer.metrics

    clock.set(day: 1, minute: 30)
    guard case .saved(let weight) = try await quickLogs.saveWeight(try #require(DecimalText("81.2")), on: TestClock.day(1)) else {
      Issue.record("the weight was not saved")
      return
    }
    _ = try await metrics.create(MetricDefinition(name: "Pages read", valueType: .count, direction: .higher), as: .general)

    #expect(weight.utcOffsetMinutes == 540 && weight.issuedOn == TestClock.day(1))
    let afterTakeover = try await context.stores.commands().filter { $0.instantMillis == TestClock.millis(day: 1, minute: 30) }
    #expect(afterTakeover.map(\.utcOffsetMinutes) == [540, 540], "weight.save and metric.create")
  }

  @Test("should create the record the command names in the same write")
  func createsTheRecordWithItsCommand() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))
    let quest = QuestRecord(id: UUID(), name: "Walk")

    let command = try await context.writer.issue(try TestQuests.creation(quest.id), creating: quest)

    #expect(try await context.stores.quests() == [quest])
    #expect(try await context.stores.commands() == [command])
  }

  @Test("should refuse content the reference refuses and write nothing")
  func refusesContent() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))
    let quest = QuestRecord(id: UUID(), name: "")

    await #expect {
      try await context.writer.issue(try TestQuests.creation(quest.id), creating: quest)
    } throws: { error in
      guard case .command(.refused(.invalidField(field: "name", problem: .required))) = error as? MemoirWriteError else { return false }
      return true
    }
    #expect(try await context.stores.quests().isEmpty)
    #expect(try await context.stores.commands().isEmpty)
  }

  @Test("should refuse text on a command with no place for it")
  func refusesUnexpectedText() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))

    await #expect {
      try await context.writer.issue(try TestQuests.zone("UTC"), text: "a note")
    } throws: { error in
      guard case .command(.refused(.textUnexpected)) = error as? MemoirWriteError else { return false }
      return true
    }
    #expect(try await context.stores.commands().isEmpty)
  }

  @Test("should roll back the record and the command when the combined write throws")
  func rollsBackACombinedWrite() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))
    let quest = QuestRecord(id: UUID(), name: "Walk")
    let body = try TestQuests.creation(quest.id)

    await #expect {
      try await context.writer.write { issuer, transaction in
        try quest.create(in: &transaction)
        try issuer.issue(body, content: quest, in: &transaction)
        throw Abandoned()
      }
    } throws: { error in
      guard case .store(.aborted(let inner)) = error as? MemoirWriteError else { return false }
      return inner is Abandoned
    }
    await #expect {
      try await context.writer.write { issuer, transaction in
        try issuer.issue(body, content: quest, in: &transaction)
        throw MemoirRecordError.absent(quest.ref)
      }
    } throws: { error in
      guard case .record(.absent(quest.ref)) = error as? MemoirWriteError else { return false }
      return true
    }
    #expect(try await context.stores.quests().isEmpty)
    #expect(try await context.stores.commands().isEmpty)
  }

  @Test("should refuse a health-class record before writing anything to the main store")
  func refusesAHealthRecordInMain() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))
    let weight = WeightRecord(date: TestClock.day0, kilograms: try #require(DecimalText("81.2")), loggedAtMillis: TestClock.millis(day: 0, minute: 720))

    await #expect {
      try await context.writer.issue(.weightSave(WeightEntry(date: TestClock.day0, confirmedReplacement: false)), creating: weight)
    } throws: { error in
      guard case .recordNotGeneral(.weight) = error as? MemoirWriteError else { return false }
      return true
    }
    #expect(try await context.stores.commands().isEmpty)
  }

  @Test("should report a write from a cancelled task as cancelled, with nothing written")
  func reportsCancelledWrites() async throws {
    let context = try await Self.open(TestClock(day: 0, minute: 720))
    let body = try TestQuests.zone("UTC")

    let outcome = await Task { () async -> MemoirWriteError? in
      withUnsafeCurrentTask { $0?.cancel() }
      do throws(MemoirWriteError) {
        try await context.writer.issue(body)
        return nil
      } catch {
        return error
      }
    }.value

    guard case .cancelled = outcome else {
      Issue.record("expected a cancelled write, got \(String(describing: outcome))")
      return
    }
    #expect(WritingErrors.presented(MemoirWriteError.cancelled) == nil)
    #expect(try await context.stores.commands().isEmpty)
  }

  @Test("should give today as the device's day before any zone is set, then as the account's")
  func givesToday() async throws {
    let clock = TestClock(day: 0, minute: 23 * 60 + 30)
    let context = try await Self.open(clock)

    #expect(try await context.today() == MemoirToday(date: TestClock.day(1), source: .deviceBeforeAnyZone))

    try await context.writer.issue(try TestQuests.zone("UTC"))

    #expect(try await context.today() == MemoirToday(date: TestClock.day(1), source: .account("UTC")), "the open day Berlin reached stays ahead of UTC's date")
  }
}

import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir commands", TestTimeLimit.quick)
struct MemoirCommandTests {
  private static let instant: Int64 = 1_795_217_400_000

  private func command(_ number: Int = 1, type: String = "quest.complete", payload: [String: JSONValue]? = nil) throws -> MemoirCommand {
    let occurrence = Occurrence(quest: MemoirStoreFixture.quest, date: try MemoirStoreFixture.date("2026-11-20"))
    return try MemoirCommand(
      id: MemoirStoreFixture.commandID(number), type: try CommandType(type),
      payload: try CommandPayload(payload ?? ["occurrence": .string("\(MemoirStoreFixture.quest.lowercasedString):2026-11-20"), "kind": "full"]), instantMillis: Self.instant,
      utcOffsetMinutes: 60, issuedOn: try MemoirStoreFixture.date("2026-11-21"), occurrence: occurrence, rulesetVersion: 1)
  }

  @Test func shouldRoundTripACommandAndListCommandsInClockOrder() async throws {
    let clock = MemoirTestClock()
    let store = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let later = try command(2)
    let earlier = try command(1, type: "quest.skip")
    for item in [later, earlier] {
      _ = try await store.write { transaction in try item.append(in: &transaction) }
      clock.advance()
    }
    let read = try await store.read { transaction in try MemoirCommand.read(id: later.id, in: transaction) }
    #expect(read.entry?.record == later)
    let listing = try await store.read { transaction in try MemoirCommand.listing(in: transaction) }
    #expect(listing.entries.map(\.record) == [later, earlier])
    #expect(listing.unreadable == 0)
  }

  @Test func shouldAppendTheSameCommandOnlyOnce() async throws {
    let first = try MemoirStore.openInMemory(.main)
    let second = try MemoirStore.openInMemory(.main)
    let item = try command()
    #expect(try await first.write { transaction in try item.append(in: &transaction) } != nil)
    #expect(try await first.write { transaction in try item.append(in: &transaction) } == nil)
    #expect(try await first.pendingChanges(limit: 10).count == 1)
    try await MemoirStoreFixture.exchange(first, second)
    #expect(try await second.write { transaction in try item.append(in: &transaction) } == nil)
    #expect(try await second.pendingChanges(limit: 10).isEmpty)
  }

  @Test func shouldRefuseADifferentCommandUnderAnIDAlreadyUsed() async throws {
    let store = try MemoirStore.openInMemory(.main)
    _ = try await store.write { transaction in try command().append(in: &transaction) }
    let other = try command(type: "quest.skip")
    let outcome = try await store.write { transaction -> MemoirRecordError? in
      do throws(MemoirRecordError) {
        try other.append(in: &transaction)
        return nil
      } catch {
        return error
      }
    }
    guard case .conflictingItem(let ref)? = outcome else { throw MemoirFixtureError(description: "expected a conflict, got \(String(describing: outcome))") }
    #expect(ref == other.ref)
  }

  @Test func shouldKeepTheOwnersWordsOutOfTheStoredCommand() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let quest = QuestRecord(id: MemoirStoreFixture.quest, name: "Morning run by the river", notes: "Knee still sore")
    let skip = try command(3, type: "quest.skip", payload: ["occurrence": .string("\(quest.id.lowercasedString):2026-11-20"), "reasonTag": "health"])
    let note = try CommandNoteRecord(command: skip.id, text: "Physio said rest this week")
    _ = try await store.write { transaction in
      try quest.create(in: &transaction)
      try skip.append(in: &transaction)
      try note.append(in: &transaction)
    }
    let commandRow = try await store.read { transaction in
      try Data.fetchOne(transaction.database, sql: "SELECT item FROM appended_item WHERE kind = ? AND key = ?", arguments: [MemoirKind.command.rawValue, skip.ref.key.rawValue])
    }
    let row = try #require(commandRow)
    let stored = String(decoding: row, as: UTF8.self)
    let lines = try await store.pendingChanges(limit: 10).map { String(decoding: $0.line, as: UTF8.self) }
    let commandLine = try #require(lines.first { $0.contains(MemoirKind.command.rawValue) })
    for text in [quest.name, "Knee still sore", note.text, "river", "Physio"] {
      #expect(!stored.contains(text))
      #expect(!commandLine.contains(text))
    }
    let item = try #require(try CanonicalJSON.decode(row, mode: .canonical).objectValue)
    #expect(Set(item.keys) == Set(CommandMember.allCases.map(\.rawValue)))
    #expect(try await store.read { transaction in try CommandNoteRecord.read(id: skip.id, in: transaction) }.entry?.record == note)
  }

  @Test func shouldRefuseFreeTextAndOddShapesInAPayload() throws {
    for text in ["Morning run", "café", "72.5", "", "line\nbreak", String(repeating: "a", count: 65)] {
      #expect(throws: MemoirCommandError.payloadText(path: "payload.word")) { try CommandPayload(["word": .string(text)]) }
    }
    #expect(throws: MemoirCommandError.payloadText(path: "payload.list[1]")) { try CommandPayload(["list": ["ok", "not ok"]]) }
    for key in ["my key", "1st", "", "naïve", "dotted.key"] {
      #expect(throws: MemoirCommandError.payloadKey(path: "payload")) { try CommandPayload([key: 1]) }
    }
    var nested: JSONValue = 1
    for _ in 0..<CommandPayload.maximumDepth { nested = ["inner": nested] }
    #expect(throws: MemoirCommandError.payloadTooDeep) { try CommandPayload(["outer": nested]) }
    let tokens: [String: JSONValue] = [
      "zone": "America/Argentina/Buenos_Aires", "offsetZone": "Etc/GMT+5", "currency": "EUR", "date": "2026-11-20", "mode": "low_intensity",
      "quest": .string(MemoirStoreFixture.quest.lowercasedString), "daysOfWeek": [1, 3, 5], "recurrence": ["interval": 2, "end": ["count": 3]], "durationMinutes": 30,
      "enabled": true, "note": .null,
    ]
    #expect(try CommandPayload(tokens).members.count == tokens.count)
  }

  @Test func shouldRefuseMeasurementsAndNumbersOutsideTheOutcomeKeys() throws {
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.calories")) { try CommandPayload(["calories": 640]) }
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.steps")) { try CommandPayload(["steps": "8042"]) }
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.offset")) { try CommandPayload(["offset": "-5"]) }
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.recurrence.end.when")) { try CommandPayload(["recurrence": ["end": ["when": 3]]]) }
    #expect(throws: MemoirCommandError.payloadNumber(path: "payload.daysOfWeek[0].bpm")) { try CommandPayload(["daysOfWeek": [["bpm": 60]]]) }
    for key in CommandPayload.measurementKeys.sorted() {
      #expect(throws: MemoirCommandError.payloadMeasurement(path: "payload.\(key)")) { try CommandPayload([key: ["metric": .string(MemoirStoreFixture.metric.lowercasedString)]]) }
    }
    #expect(throws: MemoirCommandError.payloadMeasurement(path: "payload.draft.kg")) { try CommandPayload(["draft": ["kg": 72]]) }
    for key in CommandPayload.integerKeys.sorted() { #expect(try CommandPayload([key: 1]).members.count == 1) }
  }

  @Test func shouldRefuseAMalformedCommandType() throws {
    for name in ["quest.complete", "plan.setLock", "quest.attachReason", "a.b.c"] { #expect(try CommandType(name).name == name) }
    for name in ["quest", "Quest.complete", "quest.", ".complete", "quest..complete", "quest.complete!", "quest.1complete", "quest complete"] {
      #expect(throws: MemoirCommandError.malformedType) { try CommandType(name) }
    }
  }

  @Test func shouldRefuseACommandWhoseIdentityOrDatesDoNotHold() throws {
    let type = try CommandType("quest.complete")
    let payload = try CommandPayload()
    let id = MemoirStoreFixture.commandID(1)
    let today = try MemoirStoreFixture.date("2026-11-21")
    #expect(throws: MemoirCommandError.idNotVersion7) {
      try MemoirCommand(id: UUID(), type: type, payload: payload, instantMillis: Self.instant, utcOffsetMinutes: 60, issuedOn: today, rulesetVersion: 1)
    }
    #expect(throws: MemoirCommandError.rulesetVersionOutOfRange(0)) {
      try MemoirCommand(id: id, type: type, payload: payload, instantMillis: Self.instant, utcOffsetMinutes: 60, issuedOn: today, rulesetVersion: 0)
    }
    #expect(throws: MemoirCommandError.issuedOnMismatch(expected: today, actual: try MemoirStoreFixture.date("2026-11-20"))) {
      try MemoirCommand(
        id: id, type: type, payload: payload, instantMillis: Self.instant, utcOffsetMinutes: 60, issuedOn: try MemoirStoreFixture.date("2026-11-20"), rulesetVersion: 1)
    }
    #expect(throws: MemoirCommandError.utcOffsetOutOfRange(1_081)) {
      try MemoirCommand(id: id, type: type, payload: payload, instantMillis: Self.instant, utcOffsetMinutes: 1_081, issuedOn: today, rulesetVersion: 1)
    }
    #expect(throws: MemoirCommandError.instantOutOfRange(Int64.max)) { try MemoirCommand.localDate(instantMillis: Int64.max, utcOffsetMinutes: 60) }
    #expect(throws: MemoirCommandError.instantOutOfRange(-62_167_219_200_001)) { try MemoirCommand.localDate(instantMillis: -62_167_219_200_001, utcOffsetMinutes: 0) }
    #expect(throws: MemoirCommandError.emptyNote) { try CommandNoteRecord(command: id, text: "") }
  }

  @Test func shouldDateACommandByItsInstantShiftedByItsOffset() throws {
    let cases: [(Int64, Int, String)] = [
      (Self.instant, 60, "2026-11-21"), (Self.instant, 0, "2026-11-20"), (Self.instant, -720, "2026-11-20"), (0, 0, "1970-01-01"), (-1, 0, "1969-12-31"),
      (-86_400_000, 0, "1969-12-31"), (-86_400_001, 0, "1969-12-30"), (59_999, -1, "1969-12-31"), (-62_167_219_200_000, 0, "0000-01-01"),
    ]
    for (instant, offset, expected) in cases {
      #expect(try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offset) == (try MemoirStoreFixture.date(expected)), "\(instant) \(offset)")
    }
  }

  @Test func shouldReadAStoredCommandThatBreaksTheRulesAsUnreadable() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let valid = try command().members.values
    let stray = MemoirCommand.ref(MemoirStoreFixture.commandID(7))
    let wordy = MemoirCommand.ref(MemoirStoreFixture.commandID(8))
    let random = MemoirCommand.ref(UUID())
    _ = try await store.write { transaction in
      _ = try transaction.append(stray, item: valid.merging(["reason": "felt off"]) { $1 })
      _ = try transaction.append(wordy, item: valid.merging(["payload": ["note": "felt off today"]]) { $1 })
      _ = try transaction.append(random, item: valid)
    }
    let readings = try await store.read { transaction in
      [try MemoirCommand.read(stray, in: transaction), try MemoirCommand.read(wordy, in: transaction), try MemoirCommand.read(random, in: transaction)]
    }
    #expect(readings[0] == .unreadable(.unexpected(field: "reason")))
    #expect(readings[1] == .unreadable(.invalid(field: "payload")))
    #expect(readings[2] == .unreadable(.command(.idNotVersion7)))
    #expect(try await store.read { transaction in try MemoirCommand.listing(in: transaction) }.unreadable == 3)
  }
}

extension MemoirCommand {
  fileprivate static func read(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> MemoirReading<AppendedEntry<MemoirCommand>> {
    reading(try transaction.state(of: ref, scope: .vault), of: ref)
  }
}

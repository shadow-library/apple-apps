import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import MemoirCore

@Suite("Memoir read observation and day turns", TestTimeLimit.quick)
struct ReadObservationTests {
  private typealias Device = ReadsDevice

  private static func date(_ day: LocalDate, minute: Int) -> Date {
    Date(timeIntervalSince1970: Double(Device.stamp(day, minute: minute).instantMillis) / 1000)
  }

  @Test func shouldReEmitAfterACommandIsAppendedAndWhenTheDayTurns() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.walk(to: Device.day(0))
    var boards = device.store.observe(TodayBoard.self, TodayBoardQuery(date: Device.day(0))).makeAsyncIterator()

    let first = try #require(try await boards.next())
    #expect(try first.occurrence(of: Device.routine).status == .open && first.relation == .today)
    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 490)
    let completed = try #require(try await boards.next())
    #expect(try completed.occurrence(of: Device.routine).status == .recorded(.completed))

    let waits = Mutex<[Date]>([])
    let turns = ProjectionDayTurns(
      store: device.store, reconciler: device.reconciler, deviceZone: { .gmt },
      now: { Self.date(Device.day(0), minute: 600) },
      waitUntil: { until in
        let count = waits.withLock { waits in
          waits.append(until)
          return waits.count
        }
        if count > 1 { try await Task.sleep(for: .seconds(3_600)) }
        device.horizon.set(Device.stamp(Device.day(1), minute: 1))
      })
    let running = Task { try await turns.run() }
    defer { running.cancel() }
    let turned = try #require(try await boards.next())
    #expect(turned.relation == .past && turned.changesOn == Device.day(2))
    #expect(try turned.occurrence(of: Device.anchor).status == .recorded(.missed), "the turn closed the day without a write of the owner's")
    #expect(waits.withLock { $0.first } == Self.date(Device.day(1), minute: 0))
  }

  @Test func shouldTurnAtTheNextMidnightOfTheZoneInForce() throws {
    let device = try Device()
    let berlin = AccountZone(inForce: "Europe/Berlin", openDay: Device.day(0), lastRecordedOffsetMinutes: 60, staged: nil)
    let turns = ProjectionDayTurns(store: device.store, reconciler: device.reconciler, deviceZone: { TimeZone(identifier: "Asia/Tokyo")! })
    let instant = { (text: String) throws -> Date in try #require(ISO8601DateFormatter().date(from: text)) }
    #expect(try turns.nextTurn(after: instant("2026-03-02T22:30:00Z"), zone: berlin) == instant("2026-03-02T23:00:00Z"))
    #expect(try turns.nextTurn(after: instant("2026-03-02T23:30:00Z"), zone: berlin) == instant("2026-03-03T23:00:00Z"))
    #expect(try turns.nextTurn(after: instant("2026-03-28T12:00:00Z"), zone: berlin) == instant("2026-03-28T23:00:00Z"), "the day before the clocks go forward")
    #expect(try turns.nextTurn(after: instant("2026-03-02T12:00:00Z"), zone: .unset) == instant("2026-03-02T15:00:00Z"), "the device's zone before any is set")
  }

  /// AGENTS.md: the horizon and the day turns follow the zone in force on the account's day, and the staged zone once that day has passed.
  @Test func shouldLetAStagedZoneTakeOverAtItsFirstDay() async throws {
    let builder = try Device()
    let now = Mutex(Self.date(Device.day(0), minute: 1_200))
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    let reconciler = try MemoirReconciler(appVersion: "1", now: { now.withLock { $0 } }, deviceZone: { berlin })
    let store = try MemoirStore.openInMemory(.main, projection: reconciler)
    let commands = [
      try builder.command(.accountSetTimeZone(try TimeZoneChange(identifier: "UTC")), on: Device.day(0), minute: 1),
      try builder.command(.questCreate(QuestCreation(questId: Device.routine, schedule: try Device.schedule(.routine, start: 480))), on: Device.day(0), minute: 2),
      try builder.command(.accountSetTimeZone(try TimeZoneChange(identifier: "Asia/Tokyo")), on: Device.day(0), minute: 600),
    ]
    _ = try await store.write { transaction in for command in commands { try command.append(in: &transaction) } }

    let staged = try await AccountZone.load(from: store)
    #expect(
      staged
        == AccountZone(
          inForce: "UTC", openDay: Device.day(0), lastRecordedOffsetMinutes: 0, staged: AccountZone.Staged(identifier: "Asia/Tokyo", issuedUnderOffsetMinutes: 0)))
    #expect(staged.stagedFirstDay == Device.day(1))
    #expect(staged.clock(at: Self.date(Device.day(0), minute: 1_439), device: berlin).timeZone.secondsFromGMT() == 0, "the open day still runs in UTC")
    #expect(staged.clock(at: Self.date(Device.day(1), minute: 30), device: berlin).timeZone.identifier == "Asia/Tokyo")
    #expect(staged.source(at: Self.date(Device.day(0), minute: 1_439), device: berlin) == .account("UTC"))
    #expect(staged.source(at: Self.date(Device.day(1), minute: 30), device: berlin) == .staged("Asia/Tokyo"))
    let turns = ProjectionDayTurns(store: store, reconciler: reconciler, deviceZone: { berlin })
    #expect(try turns.nextTurn(after: now.withLock { $0 }, zone: staged) == Self.date(Device.day(1), minute: 0), "the turn is UTC's midnight")

    now.withLock { $0 = Self.date(Device.day(1), minute: 30) }
    try await reconciler.refresh(store)
    let promoted = try await AccountZone.load(from: store)
    #expect(promoted == AccountZone(inForce: "Asia/Tokyo", openDay: Device.day(1), lastRecordedOffsetMinutes: 0, staged: nil))
    #expect(try await store.load(TodayBoard.self, TodayBoardQuery(date: Device.day(1))).relation == .today)
    #expect(try turns.nextTurn(after: now.withLock { $0 }, zone: promoted) == Self.date(Device.day(1), minute: 15 * 60), "Tokyo's next midnight")
  }

  /// A zone this device's data lacks keeps the offset last recorded for it rather than following the device, and says so.
  @Test func shouldKeepTheLastRecordedOffsetForAZoneThisDeviceDoesNotKnow() {
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    let noon = Self.date(Device.day(0), minute: 720)
    #expect(AccountZone.unset.source(at: noon, device: berlin) == .deviceBeforeAnyZone)
    #expect(AccountZone.unset.clock(at: noon, device: berlin).timeZone == berlin)

    let unknown = AccountZone(inForce: "Mars/Olympus_Mons", openDay: Device.day(0), lastRecordedOffsetMinutes: 330, staged: nil)
    #expect(unknown.source(at: noon, device: berlin) == .unknownZone(identifier: "Mars/Olympus_Mons", fallbackOffsetMinutes: 330))
    #expect(unknown.clock(at: noon, device: berlin).timeZone.secondsFromGMT() == 330 * 60)
    #expect(unknown.horizon(at: noon, device: berlin)?.utcOffsetMinutes == 330, "the horizon keeps the recorded offset, not the device's")
    let unrecorded = AccountZone(inForce: "Mars/Olympus_Mons", openDay: Device.day(0), lastRecordedOffsetMinutes: nil, staged: nil)
    #expect(unrecorded.source(at: noon, device: berlin) == .unknownZone(identifier: "Mars/Olympus_Mons", fallbackOffsetMinutes: nil))
    #expect(unrecorded.clock(at: noon, device: berlin).timeZone == berlin)

    let stagedUnknown = AccountZone(
      inForce: "UTC", openDay: Device.day(0), lastRecordedOffsetMinutes: 0, staged: AccountZone.Staged(identifier: "Mars/Olympus_Mons", issuedUnderOffsetMinutes: 60))
    #expect(stagedUnknown.source(at: noon, device: berlin) == .account("UTC"))
    let afterTurn = Self.date(Device.day(0), minute: 23 * 60 + 30)
    #expect(stagedUnknown.source(at: afterTurn, device: berlin) == .unknownZone(identifier: "Mars/Olympus_Mons", fallbackOffsetMinutes: 60))
    #expect(stagedUnknown.clock(at: afterTurn, device: berlin).timeZone.secondsFromGMT() == 3_600, "the offset the change was issued under")
  }
}

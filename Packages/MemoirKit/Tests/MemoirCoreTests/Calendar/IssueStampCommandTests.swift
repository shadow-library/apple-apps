import Foundation
import MemoirCore
import ShadowTestSupport
import Testing

@Suite("Issue stamps and commands", TestTimeLimit.quick)
struct IssueStampCommandTests {
  private static let zones = [
    "UTC", "America/New_York", "America/St_Johns", "Asia/Kolkata", "Asia/Kathmandu", "Pacific/Chatham", "Pacific/Kiritimati", "Pacific/Pago_Pago",
    "Australia/Lord_Howe", "America/Santiago", "Africa/Monrovia",
  ]
  private static let millisPerDay: Int64 = 86_400_000

  private static func clock(_ identifier: String) throws -> IssueClock {
    IssueClock(timeZone: try #require(TimeZone(identifier: identifier)))
  }

  @Test("should stamp an issuedOn that MemoirCommand's date check derives again from the recorded instant and offset, around every midnight")
  func stampsPassTheCommandDateCheck() throws {
    let clocks = try Self.zones.map(Self.clock)
    try forAll(iterations: 300) { generator in
      let utcMidnight = Int64(generator.int(in: -2_000...22_000)) * Self.millisPerDay
      for clock in clocks {
        let localMidnight = utcMidnight - Int64(clock.utcOffsetMinutes(at: utcMidnight)) * 60_000
        for instant in stride(from: localMidnight - 120_000, through: localMidnight + 120_000, by: 7_500) {
          let stamp = try clock.stamp(at: instant)
          let checked = try MemoirCommand.localDate(instantMillis: stamp.instantMillis, utcOffsetMinutes: stamp.utcOffsetMinutes)
          #expect(checked == stamp.issuedOn, "\(clock.timeZone.identifier) at \(instant)")
        }
      }
    }
  }

  @Test("should floor a seconds offset to whole minutes and date the stamp by that minute offset, as the command record checks it")
  func secondsOffset() throws {
    let monrovia = try Self.clock("Africa/Monrovia")
    let wallMidnight = try #require(LocalDate(isoString: "1970-06-01")).daysSinceEpoch
    let instant = Int64(wallMidnight) * Self.millisPerDay + 2_670_000 + 15_000
    #expect(monrovia.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant / 1000))) == -2_670)
    let stamp = try monrovia.stamp(at: instant)
    #expect(stamp.utcOffsetMinutes == -45)
    #expect(try monrovia.localDate(at: instant).isoString == "1970-06-01")
    #expect(stamp.issuedOn.isoString == "1970-05-31")
    #expect(try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: stamp.utcOffsetMinutes) == stamp.issuedOn)
  }
}

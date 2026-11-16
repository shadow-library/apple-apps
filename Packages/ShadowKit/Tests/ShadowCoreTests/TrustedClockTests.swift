import Foundation
import Synchronization
import Testing

@testable import ShadowCore

private final class FakeMonotonic: MonotonicTimeSource {
  private let value = Mutex<UInt64>(1_000_000_000)

  func nanoseconds() -> UInt64 { value.withLock { $0 } }
  func advance(seconds: Double) { value.withLock { $0 += UInt64(seconds * 1_000_000_000) } }
  func set(seconds: Double) { value.withLock { $0 = UInt64(seconds * 1_000_000_000) } }
}

private final class TickingMonotonic: MonotonicTimeSource {
  private let value = Mutex<UInt64>(1_000_000_000)

  func nanoseconds() -> UInt64 {
    value.withLock {
      $0 += 1
      return $0
    }
  }
}

private final class FakeWall: Sendable {
  private let value: Mutex<Date>

  init(_ date: Date) { value = Mutex(date) }

  var date: Date { value.withLock { $0 } }
  func set(_ date: Date) { value.withLock { $0 = date } }
}

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func makeClock(wall: FakeWall? = nil, restored: TrustedClockSnapshot? = nil) -> (TrustedClock, FakeMonotonic, FakeWall) {
  let monotonic = FakeMonotonic()
  let wall = wall ?? FakeWall(base)
  return (TrustedClock(wallClock: { wall.date }, monotonic: monotonic, restored: restored), monotonic, wall)
}

@Suite("TrustedClock")
struct TrustedClockTests {
  @Test("should be unavailable with no data")
  func unavailable() {
    let (clock, _, _) = makeClock()
    #expect(clock.now() == .unavailable)
    #expect(clock.snapshot == nil)
    #expect(clock.deviceClockSkew() == nil)
    #expect(clock.isDeviceClockWrong() == nil)
    #expect(clock.isTooFarAhead(base) == nil)
  }

  @Test("should report a lower bound from a restored snapshot")
  func restored() {
    let (clock, monotonic, _) = makeClock(restored: TrustedClockSnapshot(serverDate: base))
    monotonic.advance(seconds: 500)
    #expect(clock.now() == .lowerBound(base))
    #expect(clock.snapshot == TrustedClockSnapshot(serverDate: base))
    #expect(clock.deviceClockSkew() == nil)
    #expect(clock.isDeviceClockWrong() == nil)
  }

  @Test("should return nil from isTooFarAhead when only a lower bound or nothing is known")
  func tooFarAheadWithoutEstimate() {
    let (clock, _, _) = makeClock(restored: TrustedClockSnapshot(serverDate: base))
    #expect(clock.isTooFarAhead(base.addingTimeInterval(10 * 86_400)) == nil)
  }

  @Test("should prefer a live sample over a restored snapshot")
  func liveBeatsRestored() {
    let (clock, _, _) = makeClock(restored: TrustedClockSnapshot(serverDate: base.addingTimeInterval(9_999)))
    clock.record(serverDate: base)
    #expect(clock.now() == .estimate(base))
    #expect(clock.snapshot == TrustedClockSnapshot(serverDate: base))
  }

  @Test("should advance the estimate with monotonic time while the wall clock is frozen or wrong")
  func advances() {
    let (clock, monotonic, wall) = makeClock()
    clock.record(serverDate: base)
    monotonic.advance(seconds: 120)
    wall.set(base.addingTimeInterval(-50_000))
    #expect(clock.now() == .estimate(base.addingTimeInterval(120)))
    #expect(clock.snapshot?.serverDate == base.addingTimeInterval(120))
  }

  @Test("should ignore one outlier among five samples")
  func medianIgnoresOutlier() {
    let (clock, monotonic, _) = makeClock()
    for index in 0..<5 {
      clock.record(serverDate: index == 2 ? base.addingTimeInterval(1_000_000) : base.addingTimeInterval(Double(index * 10)))
      monotonic.advance(seconds: 10)
    }
    #expect(clock.now() == .estimate(base.addingTimeInterval(50)))
  }

  @Test("should keep only the five most recent samples")
  func keepsFive() {
    let (clock, monotonic, _) = makeClock()
    for _ in 0..<5 { clock.record(serverDate: base.addingTimeInterval(-100_000)) }
    for _ in 0..<5 { clock.record(serverDate: base) }
    monotonic.advance(seconds: 10)
    #expect(clock.now() == .estimate(base.addingTimeInterval(10)))
  }

  @Test("should report device clock skew with sign and magnitude")
  func skew() {
    let (clock, _, wall) = makeClock()
    clock.record(serverDate: base)
    wall.set(base.addingTimeInterval(90))
    #expect(clock.deviceClockSkew() == .seconds(90))
    wall.set(base.addingTimeInterval(-45))
    #expect(clock.deviceClockSkew() == .seconds(-45))
  }

  @Test("should flag the device clock only beyond the tolerance on either side")
  func deviceClockWrong() {
    let (clock, _, wall) = makeClock()
    clock.record(serverDate: base)
    wall.set(base.addingTimeInterval(299))
    #expect(clock.isDeviceClockWrong() == false)
    wall.set(base.addingTimeInterval(301))
    #expect(clock.isDeviceClockWrong() == true)
    wall.set(base.addingTimeInterval(-299))
    #expect(clock.isDeviceClockWrong() == false)
    wall.set(base.addingTimeInterval(-301))
    #expect(clock.isDeviceClockWrong() == true)
    #expect(clock.isDeviceClockWrong(tolerance: .seconds(600)) == false)
  }

  @Test("should flag dates more than a day ahead of the estimate")
  func tooFarAhead() {
    let (clock, _, _) = makeClock()
    clock.record(serverDate: base)
    #expect(clock.isTooFarAhead(base.addingTimeInterval(86_399)) == false)
    #expect(clock.isTooFarAhead(base.addingTimeInterval(86_401)) == true)
    #expect(clock.isTooFarAhead(base.addingTimeInterval(-86_401)) == false)
    #expect(clock.isTooFarAhead(base.addingTimeInterval(100), tolerance: .seconds(50)) == true)
  }

  @Test("should drop older samples when the monotonic source goes backwards")
  func monotonicBackwards() {
    let (clock, monotonic, _) = makeClock()
    monotonic.set(seconds: 5_000)
    clock.record(serverDate: base.addingTimeInterval(-100_000))
    clock.record(serverDate: base.addingTimeInterval(-100_000))
    monotonic.set(seconds: 10)
    clock.record(serverDate: base)
    #expect(clock.now() == .estimate(base))
  }

  @Test("should fall back to the restored bound when every sample predates a backwards jump")
  func monotonicBackwardsDropsAll() {
    let (clock, monotonic, _) = makeClock(restored: TrustedClockSnapshot(serverDate: base))
    monotonic.set(seconds: 5_000)
    clock.record(serverDate: base.addingTimeInterval(10))
    monotonic.set(seconds: 10)
    #expect(clock.now() == .lowerBound(base))
  }

  @Test("should record a parsed HTTP date header and ignore garbage")
  func recordHeader() {
    let (clock, _, _) = makeClock()
    clock.record(httpDateHeader: "not a date")
    #expect(clock.now() == .unavailable)
    clock.record(httpDateHeader: "Sun, 06 Nov 1994 08:49:37 GMT")
    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 784_111_777)))
  }

  @Test("should not lose samples or drift under concurrent record and now calls")
  func concurrency() async {
    let clock = TrustedClock(wallClock: { base }, monotonic: TickingMonotonic())
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<2_000 {
        group.addTask {
          if index % 2 == 0 { clock.record(serverDate: base) } else { _ = clock.now() }
        }
      }
    }
    #expect(clock.sampleCount == 5)
    guard case .estimate(let estimate) = clock.now() else {
      Issue.record("expected an estimate")
      return
    }
    #expect(estimate >= base)
    #expect(estimate < base.addingTimeInterval(0.001))
    #expect(clock.snapshot == TrustedClockSnapshot(serverDate: estimate))
  }
}

@Suite("TrustedClock HTTP dates")
struct HTTPDateTests {
  private let expected = Date(timeIntervalSince1970: 784_111_777)

  @Test("should parse IMF-fixdate")
  func imf() {
    #expect(TrustedClock.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT") == expected)
  }

  @Test("should parse RFC 850")
  func rfc850() {
    #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT", referenceYear: 2026) == expected)
  }

  @Test("should parse asctime with padded and unpadded days")
  func asctime() {
    #expect(TrustedClock.parseHTTPDate("Sun Nov  6 08:49:37 1994") == expected)
    #expect(TrustedClock.parseHTTPDate("Sun Nov 06 08:49:37 1994") == expected)
  }

  @Test("should ignore a day name that does not match the date")
  func mismatchedDayName() {
    #expect(TrustedClock.parseHTTPDate("Fri, 06 Nov 1994 08:49:37 GMT") == expected)
  }

  @Test("should read two-digit years more than fifty years ahead as the past century")
  func twoDigitYears() {
    func year(_ yy: String) -> Date? { HTTPDate.parse("Monday, 01-Jan-\(yy) 00:00:00 GMT", referenceYear: 2026) }
    #expect(year("76") == Date(timeIntervalSince1970: 3_345_062_400))
    #expect(year("77") == Date(timeIntervalSince1970: 220_924_800))
    #expect(year("26") == Date(timeIntervalSince1970: 1_767_225_600))
    #expect(year("94") == Date(timeIntervalSince1970: 757_382_400))
  }

  @Test("should accept leap days only in leap years")
  func leapDays() {
    #expect(TrustedClock.parseHTTPDate("Thu, 29 Feb 2024 00:00:00 GMT") == Date(timeIntervalSince1970: 1_709_164_800))
    #expect(TrustedClock.parseHTTPDate("Wed, 29 Feb 2023 00:00:00 GMT") == nil)
    #expect(TrustedClock.parseHTTPDate("Mon, 29 Feb 1900 00:00:00 GMT") == nil)
    #expect(TrustedClock.parseHTTPDate("Tue, 29 Feb 2000 00:00:00 GMT") == Date(timeIntervalSince1970: 951_782_400))
    #expect(TrustedClock.parseHTTPDate("Mon, 29 Feb 2100 00:00:00 GMT") == nil)
    #expect(TrustedClock.parseHTTPDate("Sun, 28 Feb 2100 00:00:00 GMT") == Date(timeIntervalSince1970: 4_107_456_000))
    #expect(TrustedClock.parseHTTPDate("Mon, 01 Mar 2100 00:00:00 GMT") == Date(timeIntervalSince1970: 4_107_542_400))
  }

  @Test("should apply the calendar rules to two-digit years in RFC 850")
  func rfc850Calendar() {
    #expect(HTTPDate.parse("Monday, 29-Feb-00 00:00:00 GMT", referenceYear: 2100) == nil)
    #expect(HTTPDate.parse("Sunday, 28-Feb-00 00:00:00 GMT", referenceYear: 2100) == Date(timeIntervalSince1970: 4_107_456_000))
    #expect(HTTPDate.parse("Tuesday, 29-Feb-00 00:00:00 GMT", referenceYear: 2026) == Date(timeIntervalSince1970: 951_782_400))
  }

  @Test(
    "should reject malformed input",
    arguments: [
      "",
      "garbage",
      "Sun, 06 Nov 1994 08:49:37",
      "Sun, 06 Nov 1994 08:49:37 UTC",
      "Sun, 06 Nov 94 08:49:37 GMT",
      "Sun, 32 Nov 1994 08:49:37 GMT",
      "Sun, 31 Nov 1994 08:49:37 GMT",
      "Sun, 00 Nov 1994 08:49:37 GMT",
      "Sun, 06 Foo 1994 08:49:37 GMT",
      "Sun, 06 Nov 1994 24:00:00 GMT",
      "Sun, 06 Nov 1994 08:60:37 GMT",
      "Sun, 06 Nov 1994 08:49:60 GMT",
      "Sun, 06 Nov 1994 8:49:37 GMT",
      "Sun, 06 Nov 1994 08:49 GMT",
      "Xyz, 06 Nov 1994 08:49:37 GMT",
      "Sun 06 Nov 1994 08:49:37 GMT",
      "Sunday, 06-Nov-1994 08:49:37 GMT",
      "Sunday, 06-Nov-94 08:49:37",
      "Sunday, 06/Nov/94 08:49:37 GMT",
      "Sun Nov  6 08:49:37",
      "Sun Nov 32 08:49:37 1994",
      "Sun Nov  6 08:49:37 94",
      "Sun, +6 Nov 1994 08:49:37 GMT",
      "Sun, 06 Nov 1994 08:49:37 GMT extra",
      "Sun, ٠٦ Nov 1994 08:49:37 GMT",
      "Sun,  06 Nov 1994 08:49:37 GMT",
      "Sun, 06  Nov 1994 08:49:37 GMT",
      "Sun, 06 Nov 1994  08:49:37 GMT",
      "Sun, 06 Nov 1994 08:49:37  GMT",
      "Sun, 06 Nov 1994 08:49:37 GMT ",
      " Sun, 06 Nov 1994 08:49:37 GMT",
      "Sunday,  06-Nov-94 08:49:37 GMT",
      "Sunday, 06-Nov-94  08:49:37 GMT",
      "Sunday, 06-Nov-94 08:49:37  GMT",
      "Sun  Nov 06 08:49:37 1994",
      "Sun Nov  06 08:49:37 1994",
      "Sun Nov   6 08:49:37 1994",
      "Sun Nov 6  08:49:37 1994",
    ])
  func malformed(_ input: String) {
    #expect(TrustedClock.parseHTTPDate(input) == nil)
  }
}

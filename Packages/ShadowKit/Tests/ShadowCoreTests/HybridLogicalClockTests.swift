import Foundation
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

private final class FakeWallClock: Sendable {
  private let current: Mutex<Date>

  init(millis: Int64) {
    current = Mutex(Date(timeIntervalSince1970: Double(millis) / 1_000))
  }

  func set(millis: Int64) {
    current.withLock { $0 = Date(timeIntervalSince1970: Double(millis) / 1_000) }
  }

  var date: Date {
    current.withLock { $0 }
  }
}

private let replicaA = ReplicaID(UUID(uuidString: "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b") ?? UUID())
private let replicaB = ReplicaID(UUID(uuidString: "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1c") ?? UUID())

private func stamp(_ wall: Int64, _ counter: UInt16 = 0, _ replica: ReplicaID = replicaA) throws -> HLCTimestamp {
  try #require(HLCTimestamp(wallMillis: wall, counter: counter, replica: replica))
}

private func randomReplica(_ generator: inout SeededGenerator) -> ReplicaID {
  ReplicaID(UUID(uuid: ReplicaIDTests.randomUUIDBytes(&generator)))
}

@Suite("HLCTimestamp")
struct HLCTimestampTests {
  @Test("should order by wall time then counter then replica")
  func shouldOrderByWallThenCounterThenReplica() throws {
    #expect(try stamp(1, 9, replicaB) < stamp(2, 0, replicaA))
    #expect(try stamp(2, 0, replicaB) < stamp(2, 1, replicaA))
    #expect(try stamp(2, 1, replicaA) < stamp(2, 1, replicaB))
    #expect(try stamp(2, 1, replicaA) == stamp(2, 1, replicaA))
  }

  @Test("should reject out of range wall times")
  func shouldRejectOutOfRangeWallTimes() {
    #expect(HLCTimestamp(wallMillis: -1, counter: 0, replica: replicaA) == nil)
    #expect(HLCTimestamp(wallMillis: HLCTimestamp.maxWallMillis + 1, counter: 0, replica: replicaA) == nil)
    #expect(HLCTimestamp(wallMillis: 0, counter: 0, replica: replicaA) != nil)
    #expect(HLCTimestamp(wallMillis: HLCTimestamp.maxWallMillis, counter: .max, replica: replicaA) != nil)
  }

  @Test("should format the documented example")
  func shouldFormatDocumentedExample() throws {
    let text = "2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b"
    let timestamp = try #require(HLCTimestamp(text))
    #expect(timestamp.counter == 3)
    #expect(timestamp.replica == replicaA)
    #expect(timestamp.description == text)
    #expect(timestamp.wallMillis == 1_794_820_364_118)
  }

  @Test("should round trip through text on random timestamps")
  func shouldRoundTripThroughText() throws {
    try forAll { generator in
      let timestamp = try Self.randomTimestamp(&generator)
      #expect(timestamp.description.utf8.count == 66)
      #expect(HLCTimestamp(timestamp.description) == timestamp)
    }
  }

  @Test("should order text bytes the same as values on random timestamps")
  func shouldOrderTextBytesLikeValues() throws {
    try forAll(iterations: 1_000) { generator in
      let first = try Self.randomTimestamp(&generator)
      let second = generator.chance(0.5) ? try Self.randomTimestamp(&generator) : try Self.neighbour(of: first, &generator)
      let bytewise = Array(first.description.utf8).lexicographicallyPrecedes(Array(second.description.utf8))
      #expect((first < second) == bytewise)
      #expect((first == second) == (first.description == second.description))
    }
  }

  @Test(
    "should reject every malformed string",
    arguments: [
      "",
      "2026-11-16T09:12:44.118Z-0003",
      "2026-11-16T09:12:44.118-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16 09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16t09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44,118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.11Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.1180Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "26-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-1-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-00003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-000A-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-000g-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-0003-0193A1B2-7C3D-7E4F-8A5B-6C7D8E9F0A1B",
      "2026-11-16T09:12:44.118Z-0003-0193a1b27c3d7e4f8a5b6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b ",
      "2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1bx",
      " 2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-13-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-00-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-00T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-31T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-02-29T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2100-02-29T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "1900-02-29T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T24:00:00.000Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:60:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:60.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "1969-12-31T23:59:59.999Z-0000-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "0000-01-01T00:00:00.000Z-0000-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1\u{0662}",
      "2026-11-16T09:12:44.11\u{0668}Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
    ])
  func shouldRejectMalformedString(text: String) {
    #expect(HLCTimestamp(text) == nil)
  }

  @Test(
    "should handle leap days, century years, month ends, the epoch and the maximum",
    arguments: [
      ("1970-01-01T00:00:00.000Z", 0),
      ("1970-01-01T00:00:00.001Z", 1),
      ("1970-01-01T23:59:59.999Z", 86_399_999),
      ("1972-02-29T00:00:00.000Z", 68_169_600_000),
      ("1972-03-01T00:00:00.000Z", 68_256_000_000),
      ("2000-02-29T12:00:00.000Z", 951_825_600_000),
      ("2000-03-01T00:00:00.000Z", 951_868_800_000),
      ("2024-02-29T23:59:59.999Z", 1_709_251_199_999),
      ("2100-02-28T23:59:59.999Z", 4_107_542_399_999),
      ("2100-03-01T00:00:00.000Z", 4_107_542_400_000),
      ("2026-01-31T00:00:00.000Z", 1_769_817_600_000),
      ("2026-04-30T23:59:59.999Z", 1_777_593_599_999),
      ("2026-12-31T23:59:59.999Z", 1_798_761_599_999),
      ("9999-12-31T23:59:59.999Z", 253_402_300_799_999),
    ] as [(String, Int64)])
  func shouldHandleCalendarBoundaries(prefix: String, millis: Int64) throws {
    let text = "\(prefix)-0000-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b"
    let parsed = try #require(HLCTimestamp(text))
    #expect(parsed.wallMillis == millis)
    #expect(parsed.description == text)
    #expect(try stamp(millis).description == text)
  }

  @Test("should reject 2100-02-29 and accept 2000-02-29")
  func shouldApplyGregorianLeapRules() {
    let suffix = "T00:00:00.000Z-0000-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b"
    #expect(HLCTimestamp("2000-02-29" + suffix) != nil)
    #expect(HLCTimestamp("2100-02-29" + suffix) == nil)
    #expect(HLCTimestamp("2400-02-29" + suffix) != nil)
    #expect(HLCTimestamp("2200-02-29" + suffix) == nil)
  }

  @Test("should agree with ISO8601FormatStyle on random whole seconds and keep Date within a millisecond")
  func shouldAgreeWithISO8601FormatStyle() throws {
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    try forAll(iterations: 500) { generator in
      let millis = Int64(generator.int(in: 0...Int(HLCTimestamp.maxWallMillis)))
      let timestamp = try #require(HLCTimestamp(wallMillis: millis, counter: 0, replica: replicaA))
      let wholeSecond = try #require(HLCTimestamp(wallMillis: millis / 1_000 * 1_000, counter: 0, replica: replicaA))
      #expect(String(wholeSecond.description.prefix(24)) == wholeSecond.date.formatted(style))
      #expect(String(timestamp.description.prefix(19)) == String(wholeSecond.description.prefix(19)))
      #expect(abs(timestamp.date.timeIntervalSince1970 - Double(millis) / 1_000) < 0.001)
    }
  }

  @Test("should agree with ISO8601FormatStyle on boundary instants")
  func shouldAgreeWithISO8601FormatStyleOnBoundaries() throws {
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    for millis: Int64 in [0, 1_000, 951_825_600_000, 1_709_251_199_000, 4_107_542_400_000, 253_402_300_799_000] {
      let timestamp = try stamp(millis)
      #expect(String(timestamp.description.prefix(24)) == Date(timeIntervalSince1970: Double(millis) / 1_000).formatted(style))
    }
  }

  @Test("should encode as a single JSON string inside an object")
  func shouldRoundTripInsideJSONObject() throws {
    struct Change: Codable, Equatable {
      let clock: HLCTimestamp
      let origin: ReplicaID
    }
    let change = Change(clock: try stamp(1_794_820_364_118, 3), origin: replicaB)
    let data = try JSONEncoder().encode(change)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(object["clock"] == "2026-11-16T09:12:44.118Z-0003-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b")
    #expect(object["origin"] == replicaB.description)
    #expect(try JSONDecoder().decode(Change.self, from: data) == change)
  }

  @Test("should fail to decode a malformed timestamp")
  func shouldFailToDecodeMalformedTimestamp() {
    let data = Data("\"2026-11-16T09:12:44.118Z-000A-0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b\"".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(HLCTimestamp.self, from: data) }
  }

  static func randomTimestamp(_ generator: inout SeededGenerator) throws -> HLCTimestamp {
    let wall: Int64 =
      switch generator.int(in: 0...3) {
      case 0: Int64(generator.int(in: 0...2_000))
      case 1: HLCTimestamp.maxWallMillis - Int64(generator.int(in: 0...2_000))
      default: Int64(generator.int(in: 0...Int(HLCTimestamp.maxWallMillis)))
      }
    let counter = generator.chance(0.2) ? UInt16.max - UInt16(generator.int(in: 0...3)) : UInt16(generator.int(in: 0...Int(UInt16.max)))
    return try #require(HLCTimestamp(wallMillis: wall, counter: counter, replica: randomReplica(&generator)))
  }

  static func neighbour(of base: HLCTimestamp, _ generator: inout SeededGenerator) throws -> HLCTimestamp {
    let wall = generator.chance(0.5) ? base.wallMillis : min(max(base.wallMillis + Int64(generator.int(in: -2...2)), 0), HLCTimestamp.maxWallMillis)
    let counter = generator.chance(0.5) ? base.counter : UInt16(truncatingIfNeeded: Int(base.counter) + generator.int(in: -2...2))
    let replica = generator.chance(0.5) ? base.replica : randomReplica(&generator)
    return try #require(HLCTimestamp(wallMillis: wall, counter: counter, replica: replica))
  }
}

@Suite("HybridLogicalClock")
struct HybridLogicalClockTests {
  private static func makeFrozenClock(_ wall: FakeWallClock) -> HybridLogicalClock {
    HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
  }

  @Test("should start without a latest timestamp")
  func shouldStartWithoutLatest() {
    #expect(HybridLogicalClock(replica: replicaA).latest == nil)
  }

  @Test("should issue the wall clock time with a zero counter first")
  func shouldIssueWallTimeFirst() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    #expect(clock.now() == (try stamp(5_000, 0)))
    #expect(clock.latest == (try stamp(5_000, 0)))
  }

  @Test("should strictly increase with a frozen clock")
  func shouldIncreaseWithFrozenClock() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    var previous = clock.now()
    for expected in 1..<100 {
      let next = clock.now()
      #expect(next > previous)
      #expect(next.wallMillis == 5_000)
      #expect(Int(next.counter) == expected)
      previous = next
    }
  }

  @Test("should strictly increase when the wall clock runs backwards")
  func shouldIncreaseWhenClockRunsBackwards() throws {
    let wall = FakeWallClock(millis: 10_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    let first = clock.now()
    wall.set(millis: 4_000)
    let second = clock.now()
    let third = clock.now()
    #expect(first < second)
    #expect(second < third)
    #expect(third.wallMillis == 10_000)
    wall.set(millis: 10_001)
    let fourth = clock.now()
    #expect(fourth == (try stamp(10_001, 0)))
    #expect(third < fourth)
  }

  @Test("should issue strictly greater values after observing a far future timestamp")
  func shouldExceedFarFutureObservation() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    let before = clock.now()
    let remote = try stamp(5_000_000_000_000, 7, replicaB)
    clock.observe(remote)
    let after = clock.now()
    #expect(after > remote)
    #expect(after > before)
    #expect(after.replica == replicaA)
    #expect(clock.now() > after)
  }

  @Test("should issue a greater value than a remote with an equal pair and a higher replica")
  func shouldExceedRemoteWithHigherReplica() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    let remote = try stamp(5_000, 0, replicaB)
    clock.observe(remote)
    #expect(clock.now() > remote)
  }

  @Test("should never move backwards when observing older timestamps")
  func shouldNotMoveBackwardsOnOlderObservation() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    clock.observe(try stamp(9_000, 5, replicaB))
    let latest = clock.latest
    clock.observe(try stamp(8_999, 65_535, replicaB))
    clock.observe(try stamp(9_000, 4, replicaB))
    #expect(clock.latest == latest)
    #expect(latest == (try stamp(9_000, 5, replicaA)))
  }

  @Test("should issue the wall clock value when it passes an observed timestamp")
  func shouldFollowWallClockPastObservation() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    clock.observe(try stamp(6_000, 2, replicaB))
    wall.set(millis: 6_001)
    #expect(clock.now() == (try stamp(6_001, 0)))
  }

  @Test("should roll the counter overflow into the next millisecond")
  func shouldRollCounterOverflowIntoNextMillisecond() throws {
    let wall = FakeWallClock(millis: 5_000)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date }, latest: try stamp(5_000, UInt16.max - 1))
    #expect(clock.now() == (try stamp(5_000, UInt16.max)))
    #expect(clock.now() == (try stamp(5_001, 0)))
    #expect(clock.now() == (try stamp(5_001, 1)))
  }

  @Test("should restore from latest as if it had been observed")
  func shouldRestoreFromLatest() throws {
    let wall = FakeWallClock(millis: 1_000)
    let saved = try stamp(9_000, 41, replicaA)
    let restored = HybridLogicalClock(replica: replicaA, wallClock: { wall.date }, latest: saved)
    let observing = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    observing.observe(saved)
    #expect(restored.latest == saved)
    #expect(restored.now() == (try stamp(9_000, 42)))
    #expect(observing.now() == (try stamp(9_000, 42)))
  }

  @Test("should persist and restore across instances without repeating a value")
  func shouldNotRepeatAcrossRestarts() throws {
    let wall = FakeWallClock(millis: 5_000)
    let first = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
    var seen = Set<HLCTimestamp>()
    for _ in 0..<10 { seen.insert(first.now()) }
    let second = HybridLogicalClock(replica: replicaA, wallClock: { wall.date }, latest: first.latest)
    for _ in 0..<10 { #expect(seen.insert(second.now()).inserted) }
  }

  @Test("should clamp a wall clock outside the valid range")
  func shouldClampWallClock() throws {
    let before = HybridLogicalClock(replica: replicaA, wallClock: { Date(timeIntervalSince1970: -1e12) })
    #expect(before.now() == (try stamp(0, 0)))
    #expect(before.now() == (try stamp(0, 1)))
    for extreme in [Date(timeIntervalSince1970: 1e15), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
      let clock = HybridLogicalClock(replica: replicaA, wallClock: { extreme })
      let first = clock.now()
      #expect(first.wallMillis >= 0 && first.wallMillis <= HLCTimestamp.maxWallMillis)
      #expect(clock.now() > first)
    }
    let far = HybridLogicalClock(replica: replicaA, wallClock: { Date(timeIntervalSince1970: 1e15) })
    #expect(far.now() == (try stamp(HLCTimestamp.maxWallMillis, 0)))
  }

  @Test("should saturate at the maximum timestamp without trapping")
  func shouldSaturateAtMaximum() throws {
    let wall = FakeWallClock(millis: 5_000)
    let maximum = try stamp(HLCTimestamp.maxWallMillis, UInt16.max)
    let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date }, latest: maximum)
    #expect(clock.now() == maximum)
    #expect(clock.now() == maximum)
    clock.observe(maximum)
    #expect(clock.latest == maximum)
    let nearlyMaximum = HybridLogicalClock(replica: replicaA, wallClock: { wall.date }, latest: try stamp(HLCTimestamp.maxWallMillis - 1, UInt16.max))
    #expect(nearlyMaximum.now() == (try stamp(HLCTimestamp.maxWallMillis, 0)))
  }

  @Test("should issue distinct values to 1000 concurrent calls and increase within each task")
  func shouldIssueDistinctValuesConcurrently() async throws {
    for frozen in [true, false] {
      let wall = FakeWallClock(millis: 5_000)
      let clock = frozen ? Self.makeFrozenClock(wall) : HybridLogicalClock(replica: replicaA)
      let batches = await withTaskGroup(of: [HLCTimestamp].self) { group in
        for _ in 0..<20 {
          group.addTask { (0..<50).map { _ in clock.now() } }
        }
        var collected: [[HLCTimestamp]] = []
        for await batch in group { collected.append(batch) }
        return collected
      }
      #expect(batches.count == 20)
      for batch in batches {
        #expect(batch.count == 50)
        #expect(zip(batch, batch.dropFirst()).allSatisfy { $0 < $1 })
      }
      #expect(Set(batches.flatMap { $0 }).count == 1_000)
      #expect(clock.latest == batches.flatMap { $0 }.max())
    }
  }

  @Test("should keep now strictly above every observed and issued value on random sequences")
  func shouldStayAboveEverythingSeen() throws {
    try forAll { generator in
      let wall = FakeWallClock(millis: Int64(generator.int(in: 0...100_000)))
      let clock = HybridLogicalClock(replica: replicaA, wallClock: { wall.date })
      var highest: HLCTimestamp?
      for _ in 0..<50 {
        switch generator.int(in: 0...2) {
        case 0: wall.set(millis: Int64(generator.int(in: 0...100_000)))
        case 1:
          let remote = try #require(HLCTimestamp(wallMillis: Int64(generator.int(in: 0...100_000)), counter: UInt16(generator.int(in: 0...5)), replica: randomReplica(&generator)))
          clock.observe(remote)
          highest = max(highest ?? remote, remote)
        default:
          let issued = clock.now()
          if let highest { #expect(issued > highest) }
          highest = issued
        }
      }
    }
  }
}

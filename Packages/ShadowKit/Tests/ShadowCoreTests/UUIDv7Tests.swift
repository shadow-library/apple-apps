import Foundation
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowCore

@Suite("UUIDv7")
struct UUIDv7Tests {
  private static let maxMilliseconds: Double = Double((UInt64(1) << 48) - 1)

  @Test("should set version and variant bits")
  func shouldSetVersionAndVariantBits() throws {
    try forAll { generator in
      let date = Date(timeIntervalSince1970: Double(generator.int(in: 0...4_000_000_000_000)) / 1000)
      let id = UUID.v7(at: date, using: &generator)
      let text = id.lowercasedString
      let characters = Array(text)
      #expect(characters[14] == "7")
      #expect(["8", "9", "a", "b"].contains(characters[19]))
      #expect(id.v7Timestamp != nil)
    }
  }

  @Test("should round trip the timestamp to the millisecond")
  func shouldRoundTripTimestamp() throws {
    try forAll { generator in
      let milliseconds = generator.int(in: 0...4_000_000_000_000)
      let id = UUID.v7(at: Date(timeIntervalSince1970: Double(milliseconds) / 1000), using: &generator)
      let recovered = try #require(id.v7Timestamp)
      #expect(Int((recovered.timeIntervalSince1970 * 1000).rounded()) == milliseconds)
    }
  }

  @Test("should sort ids from increasing dates in text order")
  func shouldSortByDate() {
    var generator = SeededGenerator(seed: 7)
    let ids = (0..<500).map { UUID.v7(at: Date(timeIntervalSince1970: Double($0) * 1.5), using: &generator) }
    let texts = ids.map(\.lowercasedString)
    #expect(texts == texts.sorted())
  }

  @Test("should clamp dates below the epoch to zero")
  func shouldClampBelowEpoch() throws {
    var generator = SeededGenerator(seed: 1)
    let id = UUID.v7(at: Date(timeIntervalSince1970: -5000), using: &generator)
    #expect(try #require(id.v7Timestamp).timeIntervalSince1970 == 0)
    #expect(id.lowercasedString.hasPrefix("00000000-0000-7"))
  }

  @Test("should clamp dates beyond the 48 bit range to the maximum")
  func shouldClampAboveRange() throws {
    var generator = SeededGenerator(seed: 2)
    let id = UUID.v7(at: Date(timeIntervalSince1970: 1e15), using: &generator)
    #expect((try #require(id.v7Timestamp).timeIntervalSince1970 * 1000).rounded() == Self.maxMilliseconds)
    #expect(id.lowercasedString.hasPrefix("ffffffff-ffff-7"))
  }

  @Test("should report no timestamp for a version 4 uuid")
  func shouldReportNoTimestampForV4() {
    #expect(UUID(uuidString: "f47ac10b-58cc-4372-a567-0e02b2c3d479")?.v7Timestamp == nil)
    #expect(UUID().v7Timestamp == nil)
  }

  @Test("should report no timestamp for a version 7 layout with a foreign variant")
  func shouldReportNoTimestampForForeignVariant() {
    #expect(UUID(uuidString: "0193a1b2-7c3d-7e4f-ca5b-6c7d8e9f0a1b")?.v7Timestamp == nil)
  }

  @Test("should produce the same uuid for the same seed and date")
  func shouldBeDeterministic() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    var first = SeededGenerator(seed: 99)
    var second = SeededGenerator(seed: 99)
    #expect(UUID.v7(at: date, using: &first) == UUID.v7(at: date, using: &second))
  }

  @Test("should render lower case canonical text")
  func shouldRenderLowerCase() {
    let id = UUID.v7()
    #expect(id.lowercasedString == id.uuidString.lowercased())
  }

  @Test("should generate strictly increasing ids with a frozen clock")
  func shouldIncreaseWithFrozenClock() {
    let frozen = Date(timeIntervalSince1970: 1_700_000_000)
    let generator = UUIDv7Generator(wallClock: { frozen })
    let texts = (0..<10_000).map { _ in generator.next().lowercasedString }
    #expect(zip(texts, texts.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test("should stay increasing when the clock runs backwards")
  func shouldIncreaseWhenClockRunsBackwards() {
    let seconds = Mutex(1_700_000_000.0)
    let generator = UUIDv7Generator(wallClock: { Date(timeIntervalSince1970: seconds.withLock { $0 }) })
    var texts: [String] = []
    for step in 0..<1000 {
      seconds.withLock { $0 = 1_700_000_000.0 + (step % 2 == 0 ? Double(step) : -Double(step)) }
      texts.append(generator.next().lowercasedString)
    }
    #expect(zip(texts, texts.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test("should yield distinct ids from concurrent calls")
  func shouldYieldDistinctIdsConcurrently() async {
    let generator = UUIDv7Generator()
    let ids = await withTaskGroup(of: UUID.self) { group in
      for _ in 0..<1000 { group.addTask { generator.next() } }
      var collected: [UUID] = []
      for await id in group { collected.append(id) }
      return collected
    }
    #expect(Set(ids).count == 1000)
  }

  @Test("should carry a tail overflow into the timestamp")
  func shouldCarryTailOverflow() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let milliseconds = UUID.milliseconds(of: date)
    let generator = UUIDv7Generator(wallClock: { date }, lastMilliseconds: milliseconds, lastTail: (UInt128(1) << 74) - 1)
    let id = generator.next()
    #expect((try #require(id.v7Timestamp).timeIntervalSince1970 * 1000).rounded() == Double(milliseconds + 1))
    #expect(id == UUID.make(milliseconds: milliseconds + 1, tail: 0))
    let following = generator.next()
    #expect(id.lowercasedString < following.lowercasedString)
  }
}

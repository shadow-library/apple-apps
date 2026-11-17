import Foundation
import ShadowTestSupport
import Testing

private struct Boom: Error {
  let value: Int
}

@Suite("PropertyTesting")
struct PropertyTestingTests {
  @Test("should produce the same stream for the same seed")
  func sameSeedSameStream() {
    var first = SeededGenerator(seed: 42)
    var second = SeededGenerator(seed: 42)
    #expect((0..<100).map { _ in first.next() } == (0..<100).map { _ in second.next() })
  }

  @Test("should produce different streams for different seeds")
  func differentSeedsDiffer() {
    var first = SeededGenerator(seed: 1)
    var second = SeededGenerator(seed: 2)
    #expect((0..<10).map { _ in first.next() } != (0..<10).map { _ in second.next() })
  }

  @Test("should match the SplitMix64 reference outputs for seed 0")
  func matchesReference() {
    var generator = SeededGenerator(seed: 0)
    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
    #expect(generator.next() == 0x06C4_5D18_8009_454F)
  }

  @Test("should keep int within range including single-value and full-width ranges")
  func intStaysInRange() throws {
    try forAll { generator in
      let lower = generator.int(in: -1000...1000)
      let upper = lower + generator.int(in: 0...500)
      #expect((lower...upper).contains(generator.int(in: lower...upper)))
      #expect(generator.int(in: 7...7) == 7)
      _ = generator.int(in: Int.min...Int.max)
      #expect((Int.min...(Int.min + 3)).contains(generator.int(in: Int.min...(Int.min + 3))))
      #expect(((Int.max - 3)...Int.max).contains(generator.int(in: (Int.max - 3)...Int.max)))
    }
  }

  @Test("should shuffle into a permutation and pick an element of the collection")
  func shuffleAndPick() throws {
    try forAll { generator in
      let source = Array(0..<generator.int(in: 0...20))
      #expect(generator.shuffled(source).sorted() == source)
      guard !source.isEmpty else { return }
      #expect(source.contains(generator.pick(from: source)))
    }
  }

  @Test("should respect length bounds for data and strings")
  func lengthBounds() throws {
    try forAll { generator in
      #expect(generator.data(count: 9).count == 9)
      let ascii = generator.asciiString(maxLength: 12)
      #expect(ascii.count <= 12)
      #expect(ascii.utf8.allSatisfy { (0x20...0x7E).contains($0) })
    }
  }

  @Test("should round-trip unicode strings through UTF-8")
  func unicodeRoundTrips() throws {
    try forAll { generator in
      let string = generator.unicodeString(maxLength: 40)
      #expect(String(validating: Array(string.utf8), as: UTF8.self) == string)
    }
  }

  @Test("should report a replayable seed for a failing property")
  func failureReplays() throws {
    let property: (inout SeededGenerator) throws -> Void = { generator in
      let value = generator.int(in: 0...9)
      if value < 3 { throw Boom(value: value) }
    }
    let failure = try #require(throws: PropertyFailure.self) { try forAll(property) }
    let replayed = try #require(throws: PropertyFailure.self) { try replay(seed: failure.seed, property) }
    #expect(replayed.underlying == failure.underlying)
    #expect(replayed.seed == failure.seed)
  }

  @Test("should run exactly the requested iterations for a passing property")
  func runsExactIterations() throws {
    var count = 0
    try forAll(iterations: 37) { _ in count += 1 }
    #expect(count == 37)
  }

  @Test("should run async properties and stop at the first failure")
  func asyncStopsAtFailure() async throws {
    var count = 0
    await #expect(throws: PropertyFailure.self) {
      try await forAll(iterations: 50) { _ in
        count += 1
        if count == 5 { throw Boom(value: count) }
      }
    }
    #expect(count == 5)
  }

  @Test("should draw the same case seeds concurrently as sequentially and report the lowest failing iteration")
  func concurrentMatchesSequential() async throws {
    let sequential = Seeds()
    try await forAll(iterations: 40, seed: 0xABC) { generator in sequential.record(generator.next()) }
    let concurrent = Seeds()
    try await forAllConcurrently(iterations: 40, seed: 0xABC) { generator in concurrent.record(generator.next()) }
    #expect(concurrent.sorted == sequential.sorted)

    let failure = try await #require(throws: PropertyFailure.self) {
      try await forAllConcurrently(iterations: 40, seed: 0xABC) { generator in
        if generator.next() % 2 == 0 { throw Boom(value: 1) }
      }
    }
    let expected = try await #require(throws: PropertyFailure.self) {
      try await forAll(iterations: 40, seed: 0xABC) { generator in
        if generator.next() % 2 == 0 { throw Boom(value: 1) }
      }
    }
    #expect(failure.iteration == expected.iteration)
    #expect(failure.seed == expected.seed)
  }

  @Test("should never run more iterations at once than the width")
  func concurrentRespectsWidth() async throws {
    let gauge = Gauge()
    try await forAllConcurrently(iterations: 20, seed: 1, width: 3) { _ in
      gauge.enter()
      try await Task.sleep(for: .milliseconds(5))
      gauge.leave()
    }
    #expect(gauge.peak <= 3)
    #expect(gauge.peak >= 2)
  }
}

private final class Gauge: @unchecked Sendable {
  private let lock = NSLock()
  private var running = 0
  private(set) var peak = 0

  func enter() {
    lock.withLock {
      running += 1
      peak = max(peak, running)
    }
  }

  func leave() {
    lock.withLock { running -= 1 }
  }
}

private final class Seeds: @unchecked Sendable {
  private let lock = NSLock()
  private var values = [UInt64]()

  var sorted: [UInt64] { lock.withLock { values.sorted() } }

  func record(_ value: UInt64) {
    lock.withLock { values.append(value) }
  }
}

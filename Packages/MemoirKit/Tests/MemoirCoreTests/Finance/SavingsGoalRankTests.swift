import Foundation
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Savings goal ranks", TestTimeLimit.property)
struct SavingsGoalRankTests {
  private static func rank(_ text: String) throws -> SavingsGoalRank {
    try #require(SavingsGoalRank(text))
  }

  private static func randomRank(_ generator: inout SeededGenerator, maximumLength: Int) -> SavingsGoalRank {
    while true {
      let length = generator.int(in: 1...maximumLength)
      var bytes = (0..<length).map { _ in generator.pick(from: SavingsGoalRank.digits) }
      if generator.chance(0.3) { bytes = Array(repeating: generator.pick(from: [UInt8(ascii: "0"), UInt8(ascii: "z")]), count: length - 1) + [bytes[length - 1]] }
      if let rank = SavingsGoalRank(String(decoding: bytes, as: UTF8.self)) { return rank }
    }
  }

  @Test func shouldPlaceTheFirstRankInTheMiddleAndRoomAboveAndBelowEveryRank() throws {
    #expect(SavingsGoalRank.between(nil, nil)?.text == "V")
    #expect(SavingsGoalRank.between(try Self.rank("V"), nil)?.text == "l")
    #expect(SavingsGoalRank.between(nil, try Self.rank("V"))?.text == "G")
    #expect(SavingsGoalRank.between(nil, try Self.rank("1"))?.text == "0V", "below the lowest single digit there is still room")
    #expect(SavingsGoalRank.between(try Self.rank("z"), nil)?.text == "zV")
    #expect(SavingsGoalRank.between(try Self.rank("1"), try Self.rank("2"))?.text == "1V")
    #expect(SavingsGoalRank.between(try Self.rank("1"), try Self.rank("11"))?.text == "10V", "the result never ends in the lowest digit")
  }

  @Test func shouldRefuseBoundsOutOfOrderOrEqual() throws {
    #expect(SavingsGoalRank.between(try Self.rank("b"), try Self.rank("a")) == nil)
    #expect(SavingsGoalRank.between(try Self.rank("a"), try Self.rank("a")) == nil)
  }

  @Test func shouldReturnNilRatherThanARankLongerThanTheLimit() throws {
    let longest = try Self.rank(String(repeating: "z", count: SavingsGoalRank.maximumLength))
    #expect(SavingsGoalRank.between(longest, nil) == nil)
  }

  @Test func shouldAlwaysFindAValidRankStrictlyBetweenTwoShorterThanTheLimit() throws {
    try forAll(iterations: 2_000) { generator in
      let first = Self.randomRank(&generator, maximumLength: SavingsGoalRank.maximumLength - 1)
      let second = Self.randomRank(&generator, maximumLength: SavingsGoalRank.maximumLength - 1)
      guard first != second else { return }
      let (lower, upper) = first < second ? (first, second) : (second, first)
      let middle = try #require(SavingsGoalRank.between(lower, upper), "room between \(lower) and \(upper)")
      #expect(lower < middle && middle < upper)
      #expect(SavingsGoalRank(middle.text) == middle, "\(middle) keeps the rank rules")
      #expect(lower.text.utf8.lexicographicallyPrecedes(middle.text.utf8) && middle.text.utf8.lexicographicallyPrecedes(upper.text.utf8), "byte order")
      let below = try #require(SavingsGoalRank.between(nil, lower))
      let above = try #require(SavingsGoalRank.between(upper, nil))
      #expect(below < lower && upper < above)
    }
  }

  @Test func shouldKeepFindingRoomWhenInsertingRepeatedlyAtOneSpot() throws {
    var lower = try Self.rank("1")
    let upper = try Self.rank("2")
    for _ in 0..<300 {
      let middle = try #require(SavingsGoalRank.between(lower, upper))
      #expect(lower < middle && middle < upper)
      lower = middle
    }
    #expect(lower.text.utf8.count <= SavingsGoalRank.maximumLength)
  }

  @Test func shouldSpreadRanksInOrderOverSingleDigits() throws {
    let spread = try #require(SavingsGoalRank.spread(3))
    #expect(spread.map(\.text) == ["F", "V", "k"])
    #expect(spread == spread.sorted())
    #expect(SavingsGoalRank.spread(SavingsGoalRank.digits.count) == nil)
  }
}

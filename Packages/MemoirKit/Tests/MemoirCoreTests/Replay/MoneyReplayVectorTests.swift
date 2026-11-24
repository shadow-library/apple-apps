import Foundation
import Testing

@testable import MemoirCore

/// `Fixtures/money/vectors.json`: money in the game, which the reference does not have, against outcomes worked out by hand.
@Suite("Memoir money replay vectors", TestTimeLimit.quick)
struct MoneyReplayVectorTests {
  @Test func shouldGiveEveryVectorAReasonAndAnOutcomePerStep() throws {
    let vectors = try MoneyReplayVector.all()
    #expect(vectors.count >= 20)
    for vector in vectors {
      #expect(!vector.reason.isEmpty && vector.steps.count == vector.expected.steps.count, "\(vector.id)")
    }
  }

  @Test(arguments: try MoneyReplayVector.all().map(\.id))
  func shouldMatchTheWorkedOutcomeOfEveryStep(_ id: String) throws {
    let vector = try #require(try MoneyReplayVector.all().first { $0.id == id })
    let run = try MoneyReplayRun(vector)
    #expect(run.state.halt == nil)
    for (index, (native, expected)) in zip(run.outcomes, vector.expected.steps).enumerated() {
      #expect(native == expected, "step \(index) \(vector.steps[index].type): native \(native), expected \(expected)")
    }
  }

  @Test(arguments: try MoneyReplayVector.all().map(\.id))
  func shouldEndInTheWorkedState(_ id: String) throws {
    let vector = try #require(try MoneyReplayVector.all().first { $0.id == id })
    let run = try MoneyReplayRun(vector)
    let expected = vector.expected.state
    let money = run.state.money
    if let hero = expected.hero { #expect(run.hero == hero) }
    if let covered = expected.coveredDays { #expect(run.coveredDays == covered) }
    if let streak = expected.weekStreak { #expect(money.weekStreak == streak) }
    if let start = expected.lastSettledWeekStart { #expect(money.lastSettledWeekStart?.isoString == start) }
    if let streak = expected.savingStreak { #expect(money.savingStreak == streak) }
    if let day = expected.lastActivityDay { #expect(money.lastActivityDay?.isoString == day) }
    if let closes = expected.closes { #expect(run.closes == closes) }
    for (date, multiplier) in expected.debuffs ?? [:] {
      #expect(money.debuffMultiplier(on: try MemoirStoreFixture.date(date))?.thousandths == multiplier, "\(date)")
    }
    if let returners = expected.returners { #expect(run.returners == returners) }
    if let notices = expected.notices { #expect(run.state.notices.count == notices) }
    if let achievements = expected.achievements { #expect(run.state.progression.achievements.keys.map(\.rawValue).sorted() == achievements) }
    if let logs = expected.logs { #expect(run.logs == logs) }
    if let events = expected.moneyEvents { #expect(run.moneyEvents == events) }
  }

  @Test(arguments: try MoneyReplayVector.all().map(\.id))
  func shouldDecodeEveryStateTheVectorLeavesBackToItself(_ id: String) throws {
    let vector = try #require(try MoneyReplayVector.all().first { $0.id == id })
    let state = try MoneyReplayRun(vector).state
    #expect(try ReplayState(canonicalJSON: try state.canonicalJSON()) == state)
  }
}

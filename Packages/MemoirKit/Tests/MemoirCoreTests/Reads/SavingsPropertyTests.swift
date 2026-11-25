import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Savings properties", TestTimeLimit.property)
struct SavingsPropertyTests {
  private typealias S = SavingsFixture

  private static let ranks = ["1", "F", "V", "k", "z"]
  private static let states: [SavingsGoalState] = [.active, .active, .active, .bought, .abandoned]

  @Test func shouldNeverHoldMoreThanSavingsHaveNorFillALaterGoalBeforeAnEarlierOne() throws {
    try forAll(iterations: 500) { generator in
      let goals = (0..<generator.int(in: 0...5)).map { number in
        S.goal(number, target: Int64(generator.int(in: 1...50_000)), rank: generator.pick(from: Self.ranks), state: generator.pick(from: Self.states))
      }
      let deposited = Int64(generator.int(in: 0...150_000))
      var withdrawals = [SavingsWithdrawal]()
      for number in 0..<generator.int(in: 0...4) {
        let goal = goals.isEmpty || generator.chance(0.4) ? nil : generator.pick(from: goals).id
        withdrawals.append(
          SavingsWithdrawal(
            expense: MoneyReadsFixture.id(number), occurredOn: S.today, goal: goal, currency: S.eur, amount: .converted(Int64(generator.int(in: 1...40_000)))))
      }
      let balance = deposited - withdrawals.reduce(0) { $0 + ($1.amount.minor ?? 0) }
      let allocation = SavingsAllocation.make(balanceMinor: balance, goals: goals, home: S.eur, withdrawals: withdrawals)

      #expect(allocation.active.reduce(0) { $0 + $1.shareMinor } + allocation.unallocatedMinor == max(0, balance))
      #expect(allocation.owedMinor == max(0, -balance))
      #expect(allocation.unallocatedMinor >= 0)
      for share in allocation.active { #expect(share.shareMinor >= 0 && share.shareMinor <= share.goal.targetMinor) }
      #expect(allocation.settled.allSatisfy { $0.shareMinor == 0 })
      #expect(allocation.active.map(\.goal) == allocation.active.map(\.goal).sorted(by: SavingsGoalRecord.precedes))
      if withdrawals.allSatisfy({ $0.goal == nil }) {
        for (index, share) in allocation.active.enumerated() where share.shareMinor > 0 {
          #expect(allocation.active.prefix(index).allSatisfy { $0.remainingMinor == 0 }, "a goal fills only once every goal before it is full")
        }
        if allocation.unallocatedMinor > 0 { #expect(allocation.active.allSatisfy { $0.remainingMinor == 0 }) }
      }
    }
  }

  @Test func shouldNeverNameAnEssentialCategoryAsALever() throws {
    let categories = ["food", "groceries", "transport", "bills", "health", "shopping", "home", "subs", "uncat", "travel"]
    try forAll(iterations: 200) { generator in
      var expenses = [ExpenseRecord]()
      for number in 0..<generator.int(in: 1...12) {
        let day = generator.pick(from: ["2026-08-05", "2026-09-12", "2026-10-20"])
        expenses.append(S.expense(number, Int64(generator.int(in: 1_000...400_000)), on: day, category: generator.pick(from: categories)))
      }
      let owner = categories.filter { _ in generator.chance(0.2) }.map {
        ExpenseCategoryRecord(key: MoneyReadsFixture.category($0), label: $0, essential: generator.chance(0.5))
      }
      let book = S.book(
        expenses: expenses, deposits: S.steadyDeposits, goals: [S.goal(1, target: Int64(generator.int(in: 31_000...200_000)), rank: "V")], categories: owner)
      let essentials = CategoryEssentials(records: owner)
      for forecast in try S.overview(book).forecasts {
        guard let lever = forecast.lever else { continue }
        #expect(!essentials.isEssential(lever.category), "\(lever.category.key) is essential")
        #expect(lever.category.key != "uncat")
        #expect(lever.monthsSooner >= 1)
      }
    }
  }
}

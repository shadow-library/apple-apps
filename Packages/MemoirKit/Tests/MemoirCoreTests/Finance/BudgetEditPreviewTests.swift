import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget edit preview", TestTimeLimit.quick)
struct BudgetEditPreviewTests {
  private typealias F = BudgetFixture

  private static let today = F.date("2026-11-21")
  private static let december = F.date("2026-12-01")
  private static let dollars = F.id(1)
  private static let trip = F.id(2)

  private static func monthly(limitMinor: Int64? = 30_000, staged: StagedAmount? = nil, oneOff: Int64? = nil, stagedOneOff: StagedAmount? = nil) -> LiveBudget {
    LiveBudget(
      record: BudgetRecord(
        id: dollars, name: "Dollars", currency: F.usd, limitMinor: limitMinor, period: .monthly, stagedLimit: staged, oneOffFromMinor: oneOff,
        stagedOneOff: stagedOneOff, createdOn: F.date("2026-10-01")),
      settings: nil)
  }

  private static func preview(_ budget: LiveBudget, _ change: (inout BudgetDraft) -> Void) throws(FinanceError) -> BudgetEditPreview? {
    var draft = BudgetDraft(budget, on: today)
    change(&draft)
    return try BudgetEdits.preview(draft, of: budget, today: today)
  }

  @Test func shouldPreviewNothingForADraftThatMovesNothing() throws {
    #expect(try Self.preview(Self.monthly()) { _ in } == nil)
  }

  @Test func shouldStageAMonthlyRaiseAndApplyALoweringAtOnce() throws {
    let raise = try #require(try Self.preview(Self.monthly()) { $0.limitMinor = 40_000 })
    #expect(raise.limit == .staged(StagedAmount(amountMinor: 40_000, from: Self.december), keeping: 30_000))
    #expect(raise.record.limitMinor == 30_000 && raise.record.stagedLimit == StagedAmount(amountMinor: 40_000, from: Self.december))
    #expect(raise.oneOff == nil)

    let lower = try #require(try Self.preview(Self.monthly()) { $0.limitMinor = 20_000 })
    #expect(lower.limit == .applies(dropping: nil))
  }

  @Test func shouldDropAPendingRaiseWhenTheLimitInForceIsSetAgain() throws {
    let pending = StagedAmount(amountMinor: 40_000, from: Self.december)
    let budget = Self.monthly(staged: pending)
    let back = try #require(try Self.preview(budget) { $0.limitMinor = 30_000 })
    #expect(back.limit == .applies(dropping: pending))
    #expect(back.record.stagedLimit == nil)
  }

  @Test func shouldRefuseASecondRaiseInAMonthPastItsOpeningLimitButAllowOneBackUpToIt() throws {
    let lowered = Self.monthly(staged: StagedAmount(amountMinor: 20_000, from: F.date("2026-11-01")))
    #expect(lowered.limitMinor(on: Self.today) == 20_000)
    #expect(try Self.preview(lowered) { $0.limitMinor = 30_000 }?.limit == .applies(dropping: nil))
    #expect(throws: FinanceError.limitChangedThisMonth) { try Self.preview(lowered) { $0.limitMinor = 30_001 } }
  }

  @Test func shouldApplyHomesFirstLimitToThisMonthAndThenRefuseARaise() throws {
    let settings = FinanceFixture.settings(home: F.eur)
    let home = LiveBudget(record: BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: F.date("2026-10-01")), settings: settings)
    let first = try #require(try Self.preview(home) { $0.limitMinor = 100_000 })
    #expect(first.limit == .applies(dropping: nil))
    #expect(first.record.limitMinor == nil && first.record.stagedLimit == StagedAmount(amountMinor: 100_000, from: F.date("2026-11-01")))

    let limited = LiveBudget(record: first.record, settings: settings)
    #expect(throws: FinanceError.limitChangedThisMonth) { try Self.preview(limited) { $0.limitMinor = 150_000 } }
    #expect(throws: FinanceError.homeBudgetFixed) { try Self.preview(limited) { $0.name = "Elsewhere" } }
  }

  @Test func shouldLetATripLimitOnlyGoDownOnceItHasStarted() throws {
    let started = LiveBudget(
      record: BudgetRecord(
        id: Self.trip, name: "Lisbon", currency: F.eur, limitMinor: 50_000, period: .trip(from: F.date("2026-11-20"), through: F.date("2026-11-25")),
        createdOn: F.date("2026-11-18")),
      settings: nil)
    #expect(throws: FinanceError.tripLimitLocked) { try Self.preview(started) { $0.limitMinor = 60_000 } }
    #expect(try Self.preview(started) { $0.limitMinor = 40_000 }?.limit == .applies(dropping: nil))
    #expect(throws: FinanceError.tripStartFixed) { try Self.preview(started) { $0.period = .trip(from: F.date("2026-11-21"), through: F.date("2026-11-25")) } }
  }

  @Test func shouldStageAFirstOrLowerThresholdAndApplyAHigherOneOrNoneAtOnce() throws {
    let first = try #require(try Self.preview(Self.monthly()) { $0.oneOffFromMinor = 5_000 })
    #expect(first.oneOff == .staged(StagedAmount(amountMinor: 5_000, from: Self.december), keeping: nil))
    #expect(first.limit == nil)

    let owned = Self.monthly(oneOff: 5_000)
    #expect(try Self.preview(owned) { $0.oneOffFromMinor = 6_000 }?.oneOff == .applies(dropping: nil))
    #expect(try Self.preview(owned) { $0.oneOffFromMinor = 4_000 }?.oneOff == .staged(StagedAmount(amountMinor: 4_000, from: Self.december), keeping: 5_000))

    let pending = StagedAmount(amountMinor: 4_000, from: Self.december)
    let cleared = try #require(try Self.preview(Self.monthly(oneOff: 5_000, stagedOneOff: pending)) { $0.oneOffFromMinor = nil })
    #expect(cleared.oneOff == .applies(dropping: pending))
    #expect(cleared.record.oneOffFromMinor == nil && cleared.record.stagedOneOff == nil)
  }

  @Test func shouldWriteExactlyTheRecordThePreviewShows() async throws {
    let store = try await F.store()
    _ = try await store.write { transaction in try BudgetEdits.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), id: Self.dollars, today: Self.today, in: &transaction) }
    let budget = try #require(try await F.budgets(in: store).budget(Self.dollars))
    var draft = BudgetDraft(budget, on: Self.today)
    draft.limitMinor = 45_000
    draft.oneOffFromMinor = 2_000
    let preview = try #require(try BudgetEdits.preview(draft, of: budget, today: Self.today))
    let finalDraft = draft
    let written = try await store.write { transaction in try BudgetEdits.update(Self.dollars, today: Self.today, in: &transaction) { $0 = finalDraft } }
    #expect(written == preview.record)
    #expect(try await F.record(Self.dollars, in: store) == preview.record)
  }
}

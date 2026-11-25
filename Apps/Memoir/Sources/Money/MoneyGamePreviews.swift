#if DEBUG
  import Foundation
  import MemoirCore
  import ShadowAppShell
  import ShadowCore
  import ShadowDesignSystem
  import SwiftUI

  /// A euro account scored from three months back, Home with a limit already over this month, last month closed as the closer closes it, yesterday's
  /// expense and a "No spend" two days back; with or without quests.
  enum MoneyGamePreviewData {
    static func context(quests: Bool) async -> MemoirScreenContext? {
      guard let context = try? MemoirScreenContext.inMemory() else { return nil }
      try? await seed(context, quests: quests)
      return context
    }

    static func model() async -> MoneyGameModel? {
      await context(quests: false).map { MoneyGameModel(context: $0) }
    }

    private static func seed(_ context: MemoirScreenContext, quests: Bool) async throws {
      guard let euro = CurrencyCode("EUR"), let food = CategoryKey("food") else { return }
      try await context.writer.issue(.accountSetTimeZone(try TimeZoneChange(identifier: TimeZone.current.identifier)))
      let today = try await context.today().date
      guard let start = LocalDate(year: today.year, month: today.month, day: 1)?.adding(months: -3), let yesterday = today.adding(days: -1),
        let earlier = today.adding(days: -2)
      else { return }
      try await context.writer.write { issuer, transaction in
        var settings = AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro], moneyScoredFrom: start)
        settings.setModule(.quests, enabled: quests)
        _ = try settings.create(in: &transaction)
        _ = try BudgetRecord(id: HomeBudget.id, currency: euro, limitMinor: 40_000, period: .monthly, createdOn: start).create(in: &transaction)
        let expense = ExpenseRecord(
          id: UUID(), amountMinor: 38_500, currency: euro, occurredOn: yesterday, category: food, merchant: "Market", loggedAtMillis: MemoirClock.millis(context.clock.now()))
        _ = try ExpenseEdits.create(expense, issuer: issuer, in: &transaction)
        _ = try issuer.issue(.moneyNoSpend(NoSpendDay(date: earlier)), in: &transaction)
      }
      let periods = try await BudgetCloseReads.closable(in: context.stores, today: today, now: context.clock.now())
      for period in periods {
        _ = try await context.writer.write { issuer, transaction in try BudgetCloses.close(period, issuer: issuer, in: &transaction) }
      }
      if quests { await TodayPreviewData.seed(context) }
    }
  }

  private struct MoneyGamePreviewShell: View {
    let quests: Bool
    @State private var context: MemoirScreenContext?

    var body: some View {
      Group {
        if let context { MemoirShell(context: context) } else { ProgressView() }
      }
      .environment(SyncRuntimes(identity: .memoir, factory: nil))
      .task { context = await MoneyGamePreviewData.context(quests: quests) }
    }
  }

  #Preview("Money and Hero without quests") {
    MoneyGamePreviewShell(quests: false).shadowTheme()
  }

  #Preview("Every module") {
    MoneyGamePreviewShell(quests: true).shadowTheme()
  }
#endif

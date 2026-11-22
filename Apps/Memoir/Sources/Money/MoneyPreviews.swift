#if DEBUG
  import Foundation
  import MemoirCore
  import ShadowCore
  import ShadowStore
  import SwiftUI

  /// In-memory stores with a euro account, a budget, expenses in three currencies (one waiting for a rate), two subscriptions and an archived category.
  private struct MoneyPreviewHost<Content: View>: View {
    let content: (MemoirScreenContext) -> Content
    @State private var context: MemoirScreenContext?

    var body: some View {
      NavigationStack {
        if let context {
          content(context).navigationDestination(for: MemoirRoute.self) { MemoirRouteView(route: $0, context: context) }
        } else {
          ProgressView()
        }
      }
      .task {
        guard context == nil, let context = try? MemoirScreenContext.inMemory() else { return }
        try? await Self.seed(context)
        self.context = context
      }
    }

    private static func seed(_ context: MemoirScreenContext) async throws {
      let today = try await context.today().date
      guard let euro = CurrencyCode("EUR"), let krone = CurrencyCode("NOK"), let yen = CurrencyCode("JPY"), let rate = DecimalText("0.0862"),
        let food = CategoryKey("food"), let transport = CategoryKey("transport"), let subs = CategoryKey("subs"), let home = CategoryKey("home")
      else { return }
      let millis = MemoirClock.millis(context.clock.now())
      let expenses = [
        ExpenseRecord(id: UUID(), amountMinor: 1840, currency: euro, occurredOn: today, category: food, merchant: "Café Nord", loggedAtMillis: millis),
        ExpenseRecord(id: UUID(), amountMinor: 29_900, currency: krone, occurredOn: today, category: transport, note: "Train to Bergen", loggedAtMillis: millis),
        ExpenseRecord(id: UUID(), amountMinor: 3_200, currency: yen, occurredOn: today.adding(days: -1) ?? today, category: food, note: "Ramen", loggedAtMillis: millis),
      ]
      let subscriptions = [
        SubscriptionRecord(
          id: UUID(), name: "Music", amountMinor: 1199, currency: euro, frequency: .known(.monthly), billingDay: today.day, anchorOn: today, category: subs,
          reminderEnabled: true, reminderLead: .known(.oneDay)),
        SubscriptionRecord(
          id: UUID(), name: "Cloud storage", amountMinor: 9900, currency: euro, frequency: .known(.yearly), billingDay: today.day,
          anchorOn: today.adding(days: 12) ?? today, category: subs),
      ]
      try await context.writer.write { issuer, transaction in
        try AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro, krone], monthlyBudget: MoneyAmount(amountMinor: 160_000, currency: euro))
          .create(in: &transaction)
        try FxRateRecord(base: krone, quote: euro, date: today, rate: rate).create(in: &transaction)
        for expense in expenses { try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
        for subscription in subscriptions { try SubscriptionWrites.create(subscription, issuer: issuer, in: &transaction) }
        try issuer.issue(.categorySetArchived(try CategoryArchival(categoryId: home, archived: true)), in: &transaction)
        try ExpenseCategoryRecord(key: home, label: "Home", archived: true).create(in: &transaction)
      }
    }
  }

  #Preview("Money") {
    MoneyPreviewHost { MoneyView(context: $0) }
  }

  #Preview("Subscriptions") {
    MoneyPreviewHost { SubscriptionsView(context: $0) }
  }

  #Preview("Categories") {
    MoneyPreviewHost { CategoriesView(context: $0) }
  }

  #Preview("New expense") {
    MoneyPreviewHost { ExpenseFormScreen(editing: nil, context: $0) }
  }
#endif

import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// memoir-web `SubscriptionsScreen` (`features/finance/subscriptions-screen.tsx`).
struct SubscriptionsView: View {
  @State private var model: SubscriptionsModel
  @Environment(\.locale) private var locale

  init(context: MemoirScreenContext) {
    _model = State(initialValue: SubscriptionsModel(context: context))
  }

  var body: some View {
    MoneyLoadState(model.overview.state) { overview in
      if let overview {
        content(overview)
      } else {
        ShadowContentUnavailable(
          Text("No base currency yet", tableName: "Money"), systemImage: "repeat",
          message: Text("Money totals are kept in your base currency. Choose it in Settings, under Day and money.", tableName: "Money"))
      }
    }
    .navigationTitle(Text("Subscriptions", tableName: "Money"))
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItem {
        NavigationLink(value: MemoirRoute.money(.newSubscription)) {
          Label(title: { Text("Add subscription", tableName: "Money") }, icon: { Image(systemName: "plus") })
        }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(model.overview.state.value == .some(nil))
        .shadowBarItem()
      }
    }
    .shadowScreen(.pushed)
    .task { await model.run() }
  }

  private var subtitle: Text {
    guard let overview = model.overview.state.value ?? nil else { return Text(verbatim: "") }
    let monthly = MoneyText.formatted(overview.totals.monthlyMinor, overview.home, locale: locale)
    let yearly = MoneyText.formatted(overview.totals.yearlyMinor, overview.home, locale: locale)
    return Text("\(overview.totals.activeCount) active · \(monthly) a month · \(yearly) a year", tableName: "Money")
  }

  private func content(_ overview: SubscriptionsOverview) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let note = MoneyNotes.unconvertedSubscriptions(overview.totals.pending) {
          ShadowCallout(Text(verbatim: note), intent: .warning)
        }
        if let failure = model.failure {
          ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger)
        } else if let notice = model.notice {
          ShadowCallout(
            Text(verbatim: notice), intent: .success, dismiss: ShadowCalloutDismiss(Text("Dismiss", tableName: "Money")) { model.dismissNotice() })
        }
        ShadowAdaptiveColumns {
          MoneyCard(Text("Recurring charges", tableName: "Money")) {
            if overview.items.isEmpty {
              MoneyProse(Text("Add one and Memoir will prepare its expense for you to confirm when the cycle comes due.", tableName: "Money"))
              NavigationLink(value: MemoirRoute.money(.newSubscription)) { Text("Add one", tableName: "Money") }
            }
            ForEach(overview.items, id: \.subscription.id) { standing in
              SubscriptionRow(standing: standing, home: overview.home, model: model)
            }
          }
          upcoming(overview)
          ForEach(overview.collisions, id: \.date) { collision in
            ShadowCallout(Text("Two renewals land on the same day", tableName: "Money"), message: Text(verbatim: collisionText(collision, home: overview.home)))
          }
          MoneyCard(Text("Nothing is charged for you", tableName: "Money")) {
            MoneyProse(
              Text(
                "When a cycle comes due, Memoir prepares the expense and waits. Confirming writes it once for that cycle, however many devices you confirm from.",
                tableName: "Money"))
          }
        }
      }
      .padding(Spacing.space4)
    }
  }

  private func upcoming(_ overview: SubscriptionsOverview) -> some View {
    MoneyCard(Text("Next 30 days", tableName: "Money")) {
      if overview.upcoming.isEmpty {
        MoneyProse(Text("Nothing renews in the next month.", tableName: "Money"))
      }
      ForEach(overview.upcoming, id: \.self) { charge in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: Spacing.space05) {
            Text(verbatim: model.name(of: charge.subscription) ?? "").shadowFont(.subheadline).lineLimit(1)
            Text(verbatim: MoneyDates.text(charge.dueOn, locale: locale)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
          Spacer()
          Text(verbatim: MoneyText.formatted(charge.amount, locale: locale)).shadowFont(.subheadline).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func collisionText(_ collision: SubscriptionCollision, home: CurrencyCode) -> String {
    let names = collision.subscriptions.compactMap(model.name(of:)).formatted(.list(type: .and).locale(locale))
    let day = MoneyDates.text(collision.date, locale: locale)
    let amounts =
      [collision.totalMinor.map { MoneyText.formatted($0, home, locale: locale) }].compactMap(\.self)
      + collision.unconverted.map { String(localized: "plus \(MoneyText.formatted($0, locale: locale))", table: "Money") }
    guard !amounts.isEmpty else {
      return String(localized: "\(names) renew on \(day). Nothing is wrong — it is worth knowing before the day.", table: "Money")
    }
    let together = amounts.joined(separator: " ")
    return String(localized: "\(names) renew on \(day), \(together) together. Nothing is wrong — it is worth knowing before the day.", table: "Money")
  }
}

private struct SubscriptionRow: View {
  let standing: SubscriptionStanding
  let home: CurrencyCode
  let model: SubscriptionsModel
  @Environment(\.locale) private var locale

  var body: some View {
    let subscription = standing.subscription
    VStack(alignment: .leading, spacing: Spacing.space2) {
      NavigationLink(value: MemoirRoute.money(.subscription(subscription.id))) {
        ShadowListRow(
          title: Text(verbatim: subscription.name), subtitle: Text(verbatim: meta), caption: badges, accessory: .chevron
        ) {
          ShadowSymbolTile(systemImage: MoneyLabels.categorySymbol(subscription.category))
        } trailing: {
          VStack(alignment: .trailing, spacing: Spacing.space05) {
            Text(verbatim: MoneyText.formatted(subscription.amountMinor, subscription.currency, locale: locale)).shadowFont(.body).monospacedDigit()
            Text(verbatim: subscription.frequency.known.map(MoneyLabels.frequency) ?? subscription.frequency.rawValue).shadowFont(.caption)
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .buttonStyle(.plain)
      HStack(spacing: Spacing.space2) {
        if standing.dueState == .due || standing.dueState == .overdue {
          Button {
            Task { await model.confirm(standing, locale: locale) }
          } label: {
            Text("Confirm charge", tableName: "Money")
          }
          .buttonStyle(.bordered)
        }
        Button {
          Task { await model.setActive(subscription.id, !subscription.active) }
        } label: {
          subscription.active ? Text("Pause", tableName: "Money") : Text("Resume", tableName: "Money")
        }
        .buttonStyle(.borderless)
      }
      .disabled(model.working.contains(subscription.id))
      .padding(.leading, Spacing.space4)
    }
  }

  private var badges: Text? {
    let labels = [MoneyLabels.dueState(standing.dueState), standing.subscription.active ? nil : String(localized: "Paused", table: "Money")].compactMap(\.self)
    return labels.isEmpty ? nil : Text(verbatim: labels.joined(separator: " · "))
  }

  /// memoir-web `dueLabel` and the monthly equivalent.
  private var meta: String {
    let subscription = standing.subscription
    let day = MoneyDates.text(standing.nextDue, locale: locale)
    let due: String =
      if !subscription.active {
        String(localized: "Paused — no renewals", table: "Money")
      } else if standing.dueState == .overdue {
        String(localized: "Was due \(day)", table: "Money")
      } else {
        String(localized: "Renews \(day)", table: "Money")
      }
    let category = MoneyLabels.categoryName(subscription.category)
    let equivalent: String =
      switch standing.monthlyInHome {
      case .converted(let minor) where subscription.currency == home:
        String(localized: "\(MoneyText.formatted(minor, home, locale: locale)) a month", table: "Money")
      case .converted(let minor): String(localized: "≈ \(MoneyText.formatted(minor, home, locale: locale)) a month", table: "Money")
      case .awaitingRate, .unconvertible: String(localized: "no \(subscription.currency.code) rate yet", table: "Money")
      }
    return [category, due, equivalent].joined(separator: " · ")
  }
}

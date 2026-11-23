import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// A card with the Money screens' heading.
struct MoneyCard<Accessory: View, Content: View>: View {
  let title: Text
  let accessory: Accessory
  let content: Content

  init(_ title: Text, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    ShadowCard {
      content
    } header: {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Spacer(minLength: Spacing.space2)
        accessory
      }
    }
  }
}

extension MoneyCard where Accessory == EmptyView {
  init(_ title: Text, @ViewBuilder content: () -> Content) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }
}

struct MoneyProse: View {
  let text: Text

  init(_ text: Text) {
    self.text = text
  }

  var body: some View {
    text.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
  }
}

/// What a loading or failed read shows in place of a screen.
struct MoneyLoadState<Value: Sendable & Equatable, Content: View>: View {
  let state: Loadable<Value>
  let content: (Value) -> Content

  init(_ state: Loadable<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
    self.state = state
    self.content = content
  }

  var body: some View {
    switch state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel(Text("Loading", tableName: "Money"))
    case .failed(let error):
      ShadowContentUnavailable(Text(verbatim: error.headline), kind: .error, message: error.detail.map { Text(verbatim: $0) })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let value):
      content(value)
    }
  }
}

/// memoir-web `ExpenseRow`: the title, the category, the date, the amount at home and, for a foreign expense, the amount as typed or that its rate is pending.
struct ExpenseRowContent: Equatable {
  let title: String
  let category: String
  let symbol: String
  let date: String
  let amount: String
  let secondary: String?
  let isRatePending: Bool
  let hasReceipt: Bool

  init(_ row: ExpenseRow, home: CurrencyCode?, categoryName: (CategoryKey) -> String, locale: Locale) {
    let expense = row.expense
    category = categoryName(expense.category)
    symbol = MoneyLabels.categorySymbol(expense.category)
    title = expense.note ?? expense.merchant ?? category
    date = MoneyDates.text(expense.occurredOn, locale: locale)
    hasReceipt = expense.receipt != nil
    let typed = MoneyText.formatted(expense.amountMinor, expense.currency, locale: locale)
    let foreign = home.map { $0 != expense.currency } ?? false
    switch (row.inHome, home) {
    case (.converted(let minor), let home?):
      amount = MoneyText.formatted(minor, home, locale: locale)
      secondary = foreign ? typed : nil
      isRatePending = false
    case (.awaitingRate, _):
      amount = typed
      secondary = foreign ? String(localized: "Rate pending", table: "Money") : nil
      isRatePending = foreign
    default:
      amount = typed
      secondary = foreign ? String(localized: "Can’t be converted", table: "Money") : nil
      isRatePending = false
    }
  }
}

struct ExpenseRowView: View {
  let content: ExpenseRowContent

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: content.title),
      subtitle: Text(verbatim: [content.category, content.date].joined(separator: " · ")),
      caption: content.hasReceipt ? Text("Receipt attached", tableName: "Money") : nil,
      accessory: .chevron
    ) {
      ShadowSymbolTile(systemImage: content.symbol)
    } trailing: {
      VStack(alignment: .trailing, spacing: Spacing.space05) {
        Text(verbatim: content.amount).shadowFont(.body).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
        if let secondary = content.secondary {
          Text(verbatim: secondary).shadowFont(.caption).monospacedDigit()
            .foregroundStyle(content.isRatePending ? ShadowColor.warningText : ShadowColor.textSecondary)
        }
      }
    }
    .shadowListRowSingleLineTitle()
  }
}

/// A day picked in the device's calendar and kept as the civil date.
struct LocalDatePicker: View {
  let title: Text
  @Binding var date: LocalDate
  let earliest: LocalDate?
  let latest: LocalDate?

  var body: some View {
    DatePicker(selection: binding, in: range, displayedComponents: .date) { title }
  }

  private var binding: Binding<Date> {
    Binding(get: { MoneyDates.pickerDate(date) }, set: { if let day = MoneyDates.localDate($0) { date = day } })
  }

  private var range: ClosedRange<Date> {
    let lower = earliest.map(MoneyDates.pickerDate) ?? .distantPast
    let upper = latest.map(MoneyDates.pickerDate) ?? .distantFuture
    return min(lower, upper)...max(lower, upper)
  }
}

/// The amount field: what was typed, read in the owner's locale, with the refusal under it.
struct MoneyAmountField: View {
  @Binding var text: String
  let currency: CurrencyCode
  let issue: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      TextField(text: $text, prompt: Text(verbatim: "0")) { Text("Amount", tableName: "Money") }
        .monospacedDigit()
        .autocorrectionDisabled()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
        .accessibilityHint(Text(verbatim: currency.code))
      if let issue { ShadowValidationMessage(Text(verbatim: issue)) }
    }
  }
}

/// The home currency per one unit of `currency`, as the owner types it.
struct MoneyRateField: View {
  @Binding var text: String
  let currency: CurrencyCode
  let home: CurrencyCode
  let issue: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      LabeledContent {
        TextField(text: $text, prompt: Text("Reference rate", tableName: "Money")) { label }
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
      } label: {
        label
      }
      if let issue { ShadowValidationMessage(Text(verbatim: issue)) }
    }
  }

  private var label: Text { Text("\(home.code) for 1 \(currency.code)", tableName: "Money") }
}

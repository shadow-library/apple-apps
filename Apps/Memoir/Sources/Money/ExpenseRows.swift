import Foundation
import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// The rows of a listing and what to say when it is empty, shared by the Money screen and the full list.
struct ExpenseRows: View {
  let listing: ExpenseListing
  let list: ExpenseListModel
  let locale: Locale
  @State private var rateEntry: ExpenseRecord?
  @State private var refunding: ExpenseRecord?

  var body: some View {
    if listing.rows.items.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text(verbatim: emptyTitle).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        MoneyProse(emptyMessage)
        NavigationLink(value: MemoirRoute.money(.newExpense)) { Text("Add expense", tableName: "Money") }
      }
    } else {
      VStack(spacing: 0) {
        ForEach(listing.rows.items, id: \.expense.id) { row in
          let content = ExpenseRowContent(row, home: listing.home, categoryName: { MoneyLabels.categoryName($0) }, locale: locale)
          let link = NavigationLink(value: MemoirRoute.money(.expense(row.expense.id))) { ExpenseRowView(content: content) }.buttonStyle(.plain)
          let canRefund = row.expense.amountMinor > 0
          if content.isRatePending || canRefund {
            link.contextMenu {
              if content.isRatePending {
                Button {
                  rateEntry = row.expense
                } label: {
                  Label(title: { Text("Enter the rate", tableName: "Money") }, icon: { Image(systemName: "arrow.left.arrow.right") })
                }
              }
              if canRefund {
                Button {
                  refunding = row.expense
                } label: {
                  Label(title: { Text("Refund", tableName: "Money") }, icon: { Image(systemName: "arrow.uturn.backward") })
                }
              }
            }
          } else {
            link
          }
        }
      }
      .sheet(isPresented: Binding(get: { rateEntry != nil }, set: { if !$0 { rateEntry = nil } })) {
        if let rateEntry {
          NavigationStack { ExpenseFormScreen(editing: rateEntry, context: list.context) }.shadowSheetStyle(.form)
        }
      }
      .sheet(isPresented: Binding(get: { refunding != nil }, set: { if !$0 { refunding = nil } })) {
        if let refunding {
          NavigationStack { RefundSheet(expense: refunding, context: list.context, locale: locale) }.shadowSheetStyle(.form)
        }
      }
      HStack {
        Text("Showing \(listing.rows.items.count) of \(listing.rows.total)", tableName: "Money")
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        Spacer()
        if listing.rows.hasMore {
          if list.limit <= ExpenseListModel.overviewPageSize {
            NavigationLink(value: MemoirRoute.money(.expenses(list.scope))) { Text("Show all", tableName: "Money") }
          } else {
            Button {
              list.showMore()
            } label: {
              Text("Show more", tableName: "Money")
            }
          }
        }
      }
    }
  }

  private var emptyTitle: String {
    if !list.search.isEmpty { return String(localized: "Nothing matches “\(list.search)”", table: "Money") }
    if let category = list.category { return String(localized: "No \(MoneyLabels.categoryName(category)) expenses in this range", table: "Money") }
    return String(localized: "No expenses in this range", table: "Money")
  }

  private var emptyMessage: Text {
    list.search.isEmpty
      ? Text("Add one when you spend something. Ten seconds is the whole cost.", tableName: "Money")
      : Text("Try a shorter word, or widen the range.", tableName: "Money")
  }
}

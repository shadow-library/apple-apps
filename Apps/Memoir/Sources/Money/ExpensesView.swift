import Foundation
import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// Every expense of a range, searched and paged, optionally of one category.
struct ExpensesView: View {
  @State private var list: ExpenseListModel
  @Environment(\.locale) private var locale

  init(scope: ExpenseListScope, context: MemoirScreenContext) {
    _list = State(initialValue: ExpenseListModel(context: context, scope: scope))
  }

  var body: some View {
    @Bindable var list = list
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Picker(selection: $list.range) {
          ForEach(FinanceRange.allCases, id: \.self) { range in Text(verbatim: MoneyLabels.rangeTitle(range)).tag(range) }
        } label: {
          Text("Range", tableName: "Money")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if let category = list.category {
          ShadowTag(Text(verbatim: MoneyLabels.categoryName(category)), removeLabel: Text("Remove the category filter", tableName: "Money")) {
            list.category = nil
          }
        }
        MoneyLoadState(list.listing.state) { listing in
          ExpenseRows(listing: listing, list: list, locale: locale)
        }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: ShadowMetrics.readableWidth)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(Text("Expenses", tableName: "Money"))
    .searchable(text: $list.search, prompt: Text("Search notes and merchants", tableName: "Money"))
    .shadowScreen(.pushed)
    .task { await list.run() }
  }
}

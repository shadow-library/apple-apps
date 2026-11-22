import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// memoir-web `CategoriesScreen` (`features/finance/categories-screen.tsx`).
struct CategoriesView: View {
  @State private var model: CategoriesModel
  @Environment(\.locale) private var locale

  init(context: MemoirScreenContext) {
    _model = State(initialValue: CategoriesModel(context: context))
  }

  var body: some View {
    MoneyLoadState(model.overview.state) { snapshot in
      content(snapshot.overview)
    }
    .navigationTitle(Text("Categories", tableName: "Money"))
    .navigationSubtitle(subtitle)
    .shadowScreen(.pushed)
    .task { await model.run() }
  }

  private var subtitle: Text {
    guard let overview = model.overview.state.value?.overview else { return Text(verbatim: "") }
    let archived = overview.categories.count(where: \.isArchived)
    return Text("\(overview.categories.count) categories · \(archived) archived", tableName: "Money")
  }

  private func content(_ overview: CategoriesOverview) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure {
          ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger)
        } else if let notice = model.notice {
          ShadowCallout(Text(verbatim: notice), intent: .success)
        }
        ShadowAdaptiveColumns {
          MoneyCard(Text("Every category", tableName: "Money")) {
            ForEach(overview.categories, id: \.key) { entry in
              row(entry)
            }
          }
          MoneyCard(Text("Archive safely", tableName: "Money")) {
            MoneyProse(Text("Archiving hides a category from new entries. Its past expenses keep it, and Insights keeps its history.", tableName: "Money"))
          }
          if let uncategorised = overview.uncategorised, uncategorised.count > 0 {
            MoneyCard(Text("Uncategorised", tableName: "Money")) {
              MoneyProse(Text(verbatim: uncategorisedText(uncategorised)))
              NavigationLink(value: MemoirRoute.money(.expenses(ExpenseListScope(category: uncategorised.category)))) { Text("Categorise now", tableName: "Money") }
            }
          }
        }
      }
      .padding(Spacing.space4)
    }
  }

  private func row(_ entry: CategoryEntry) -> some View {
    let slice = model.slice(of: entry.key)
    let name = MoneyLabels.categoryName(entry.key, label: entry.label)
    let count = String(localized: "\(slice?.count ?? 0) this month", table: "Money")
    let pending = slice.map { MoneyNotes.leftOut($0.pending) } ?? []
    let meta = ([MoneyLabels.categoryHint(entry.key), count].compactMap(\.self) + pending).joined(separator: " · ")
    return ShadowListRow(
      title: Text(verbatim: name), subtitle: Text(verbatim: meta), caption: entry.isArchived ? Text("Archived", tableName: "Money") : nil
    ) {
      ShadowSymbolTile(systemImage: MoneyLabels.categorySymbol(entry.key), tint: entry.isArchived ? .neutral : .accent)
    } trailing: {
      HStack(spacing: Spacing.space2) {
        Text(verbatim: model.amount(of: slice, locale: locale)).shadowFont(.subheadline).monospacedDigit()
        if !entry.isPermanent {
          Menu {
            Button {
              Task { await model.setArchived(entry.key, !entry.isArchived) }
            } label: {
              entry.isArchived ? Text("Restore", tableName: "Money") : Text("Archive", tableName: "Money")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuIndicator(.hidden)
          .accessibilityLabel(Text("Actions for \(name)", tableName: "Money"))
          .disabled(model.working.contains(entry.key))
        }
      }
    }
  }

  private func uncategorisedText(_ slice: CategorySlice) -> String {
    let total = model.amount(of: slice, locale: locale)
    return String(
      localized: "\(slice.count) expenses, \(total) this month. Categorising them takes about twenty seconds.", table: "Money")
  }
}

import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// memoir-web `ExpenseDetailScreen` (`features/finance/expense-detail-screen.tsx`).
struct ExpenseDetailView: View {
  @State private var model: ExpenseDetailModel
  @State private var isEditing = false
  @State private var isConfirmingDelete = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  init(id: UUID, context: MemoirScreenContext) {
    _model = State(initialValue: ExpenseDetailModel(id: id, context: context))
  }

  var body: some View {
    MoneyLoadState(model.history.state) { _ in
      if let deletion = model.deletion, model.expense == nil {
        deleted(deletion)
      } else if let expense = model.expense {
        content(expense)
      } else if model.isGone {
        ShadowContentUnavailable(
          Text("That expense is no longer here", tableName: "Money"), systemImage: "banknote",
          message: Text("It may have been deleted on another device.", tableName: "Money"))
      } else {
        ShadowContentUnavailable(
          Text("This expense can’t be read", tableName: "Money"), kind: .error,
          message: Text("It was written by a newer version of Memoir. Update the app to see it.", tableName: "Money"))
      }
    }
    .navigationTitle(Text("Expense", tableName: "Money"))
    .toolbar {
      if let expense = model.expense {
        ToolbarItem {
          Button {
            isEditing = true
          } label: {
            Label(title: { Text("Edit", tableName: "Money") }, icon: { Image(systemName: "pencil") })
          }
          .keyboardShortcut("e", modifiers: [.command])
          .shadowBarItem()
        }
        ToolbarItem {
          Button(role: .destructive) {
            isConfirmingDelete = true
          } label: {
            Label(title: { Text("Delete", tableName: "Money") }, icon: { Image(systemName: "trash") })
          }
          .disabled(model.isWorking)
          .shadowBarItem()
          .confirmationDialog(Text("Delete this expense?", tableName: "Money"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(role: .destructive) {
              Task { await model.delete() }
            } label: {
              Text("Delete expense", tableName: "Money")
            }
            .shadowDestructiveDialogAction()
            Button(role: .cancel) {
            } label: {
              Text("Cancel", tableName: "Money")
            }.shadowDialogCancelAction()
          } message: {
            Text(verbatim: deleteDescription(expense))
          }
        }
      }
    }
    .sheet(isPresented: $isEditing) {
      if let expense = model.expense {
        NavigationStack { ExpenseFormScreen(editing: expense, context: model.context) }.shadowSheetStyle(.form)
      }
    }
    .shadowScreen(.pushed)
    .task { await model.run() }
  }

  private func content(_ expense: ExpenseRecord) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        ShadowAdaptiveColumns {
          summary(expense)
          details(expense)
          if let home = model.home, expense.currency != home {
            MoneyCard(Text("The rate does not move", tableName: "Money")) {
              MoneyProse(
                Text(
                  "A foreign expense keeps the amount you entered and the rate it converts at. Reports convert with that rate for good — a past month never re-prices itself.",
                  tableName: "Money"))
            }
          }
          history
        }
      }
      .padding(Spacing.space4)
    }
  }

  private func summary(_ expense: ExpenseRecord) -> some View {
    let typed = MoneyText.formatted(expense.amountMinor, expense.currency, locale: locale)
    let shown = model.home.flatMap { home in model.inHome?.minor.map { MoneyText.formatted($0, home, locale: locale) } } ?? typed
    return ShadowCard {
      Text(verbatim: shown).shadowFont(.largeTitle).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
      MoneyProse(Text(verbatim: rateLine(expense, typed: typed)))
      ShadowFlowLayout {
        ShadowTag(Text(verbatim: model.categoryName(expense.category)), systemImage: MoneyLabels.categorySymbol(expense.category))
        if expense.receipt != nil { ShadowBadge(Text("Receipt attached", tableName: "Money"), systemImage: "doc.text.image") }
        if model.source == .ocr { ShadowBadge(Text("Receipt scanned", tableName: "Money"), intent: .info) }
      }
      if let receipt = expense.receipt {
        ReceiptViewerButton(receipt: receipt, subject: "\(title(expense)) · \(MoneyDates.text(expense.occurredOn, locale: locale))", context: model.context)
      }
    }
  }

  private func details(_ expense: ExpenseRecord) -> some View {
    ShadowCard {
      LabeledContent {
        Text(verbatim: expense.note ?? "—")
      } label: {
        Text("Note", tableName: "Money")
      }
      LabeledContent {
        Text(verbatim: expense.merchant ?? "—")
      } label: {
        Text("Merchant", tableName: "Money")
      }
      LabeledContent {
        Text(verbatim: MoneyDates.text(expense.occurredOn, locale: locale))
      } label: {
        Text("Date", tableName: "Money")
      }
      LabeledContent {
        Text(verbatim: MoneyText.formatted(expense.amountMinor, expense.currency, locale: locale)).monospacedDigit()
      } label: {
        Text("Amount as entered", tableName: "Money")
      }
      LabeledContent {
        Text(verbatim: converted(expense))
      } label: {
        Text("Converted", tableName: "Money")
      }
    }
  }

  private var history: some View {
    MoneyCard(Text("Edit history", tableName: "Money")) {
      let lines = model.historyLines(locale: locale)
      if lines.isEmpty {
        MoneyProse(Text("No changes recorded yet.", tableName: "Money"))
      }
      ForEach(lines) { line in
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: line.text).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: line.when).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func deleted(_ deletion: ExpenseDetailModel.Deletion) -> some View {
    ShadowContentUnavailable(
      Text("Expense deleted.", tableName: "Money"), systemImage: "trash",
      message: deletion.canUndo ? nil : Text("An expense with a receipt or from a subscription can’t be brought back.", tableName: "Money")
    ) {
      VStack(spacing: Spacing.space2) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        if deletion.canUndo {
          Button {
            Task { await model.undo() }
          } label: {
            Text("Undo", tableName: "Money")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking)
        }
        Button {
          dismiss()
        } label: {
          Text("Back to Money", tableName: "Money")
        }
      }
    }
  }

  /// memoir-web `rateLine`.
  private func rateLine(_ expense: ExpenseRecord, typed: String) -> String {
    guard let home = model.home, expense.currency != home else { return String(localized: "Entered in your base currency.", table: "Money") }
    guard let rate = model.rate, model.inHome?.minor != nil else {
      return String(localized: "\(typed) — the rate isn’t known yet, so this converts later. Nothing was blocked.", table: "Money")
    }
    let day = MoneyDates.text(expense.rate?.date ?? expense.occurredOn, locale: locale)
    return String(localized: "\(typed) at \(MoneyText.rate(rate, locale: locale)) — the rate on \(day)", table: "Money")
  }

  private func converted(_ expense: ExpenseRecord) -> String {
    guard let home = model.home else { return String(localized: "Waiting for a base currency", table: "Money") }
    switch model.inHome {
    case .converted(let minor) where expense.currency == home:
      return String(localized: "\(MoneyText.formatted(minor, home, locale: locale)) · your base currency", table: "Money")
    case .converted(let minor): return String(localized: "\(MoneyText.formatted(minor, home, locale: locale)) · locked to the transaction date", table: "Money")
    case .awaitingRate, nil: return String(localized: "Waiting for a rate — the entry saved without one.", table: "Money")
    case .unconvertible: return String(localized: "Can’t be converted to \(home.code).", table: "Money")
    }
  }

  /// memoir-web `deleteDescription`.
  private func deleteDescription(_ expense: ExpenseRecord) -> String {
    let amount = MoneyText.formatted(expense.amountMinor, expense.currency, locale: locale)
    let day = MoneyDates.text(expense.occurredOn, locale: locale)
    let removed = String(localized: "\(amount) · \(title(expense)) on \(day) leaves Money, History and Insights, and its edit history goes with it.", table: "Money")
    return expense.receipt == nil ? removed : "\(removed) \(ReceiptViewerButton.deletionNote)"
  }

  private func title(_ expense: ExpenseRecord) -> String {
    expense.note ?? expense.merchant ?? model.categoryName(expense.category)
  }
}

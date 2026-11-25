import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct RefundSheet: View {
  @State private var model: RefundModel
  @Environment(\.dismiss) private var dismiss

  init(expense: ExpenseRecord, context: MemoirScreenContext, locale: Locale) {
    _model = State(initialValue: RefundModel(expense: expense, context: context, locale: locale))
  }

  var body: some View {
    Form {
      if let failure = model.failure {
        Section { ShadowValidationMessage(failure.text) }
      }
      Section {
        Picker(selection: $model.mode) {
          Text("Full refund", tableName: "Money").tag(RefundMode.full)
          Text("Partial refund", tableName: "Money").tag(RefundMode.partial)
        } label: {
          Text("Refund", tableName: "Money")
        }
        .pickerStyle(.segmented)
        if model.mode == .partial {
          MoneyAmountField(text: $model.amountText, currency: model.currency, issue: model.amountIssue, label: Text("Amount refunded", tableName: "Money"))
        }
      } footer: {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("The expense stays in your history with what was refunded.", tableName: "Money")
          if let returned = model.returnedToSavings {
            Text("\(MoneyText.formatted(returned, model.currency, locale: model.locale)) goes back to savings.", tableName: "Money")
          }
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isSaving)
    .navigationTitle(Text("Refund", tableName: "Money"))
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          dismiss()
        } label: {
          Text("Cancel", tableName: "Money")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { if await model.save() { dismiss() } }
        } label: {
          Text("Refund", tableName: "Money")
        }
        .disabled(!model.canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
  }
}

import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Adds an expense (pushed from Money) or edits one (in a sheet from its detail), once the form's options have been read.
struct ExpenseFormScreen: View {
  let editing: ExpenseRecord?
  let context: MemoirScreenContext
  @State private var form: ExpenseForm?
  @State private var loadFailure: PresentedError?
  @Environment(\.locale) private var locale
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?
  @Environment(AIServices.self) private var services: AIServices?

  var body: some View {
    Group {
      if let form {
        ExpenseFormFields(form: form)
      } else if let loadFailure {
        ShadowContentUnavailable(Text(verbatim: loadFailure.headline), kind: .error, message: loadFailure.detail.map { Text(verbatim: $0) })
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(editing == nil ? Text("Add expense", tableName: "Money") : Text("Edit expense", tableName: "Money"))
    .shadowScreen(.pushed)
    .task {
      guard form == nil else { return }
      do {
        let options = try await MoneyOptions.load(context)
        let receipt = editing == nil ? ReceiptDraft(context: context, sync: sync, services: services) : nil
        form = ExpenseForm(mode: editing.map { .edit($0) } ?? .create, options: options, context: context, locale: locale, receipt: receipt)
      } catch {
        loadFailure = MoneyErrors.read(error)
      }
    }
  }
}

private struct ExpenseFormFields: View {
  @Bindable var form: ExpenseForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  var body: some View {
    Form {
      if let failure = form.failure {
        Section { ShadowValidationMessage(failure.text) }
      }
      Section {
        MoneyAmountField(text: $form.amountText, currency: form.currency, issue: form.amountIssue)
        Picker(selection: Binding(get: { form.currency }, set: { form.select($0) })) {
          ForEach(form.currencies, id: \.self) { code in Text(verbatim: MoneyText.currencyName(code, locale: locale)).tag(code) }
        } label: {
          Text("Currency", tableName: "Money")
        }
        .disabled(!form.canChangeCurrency)
      } footer: {
        if !form.canChangeCurrency {
          Text("A saved expense keeps its currency. To use another, delete it and add it again.", tableName: "Money")
        } else if let preview = form.preview(locale: locale) {
          Text(verbatim: preview)
        }
      }
      if form.offersRate, let home = form.options.home {
        Section {
          MoneyRateField(text: $form.rateText, currency: form.currency, home: home, issue: form.rateIssue)
        } header: {
          Text("Exchange rate", tableName: "Money")
        } footer: {
          Text(
            "Leave it empty to use the European Central Bank’s rate for the expense’s date. A rate you enter converts this expense only.", tableName: "Money")
        }
      }
      Section {
        Picker(selection: $form.category) {
          ForEach(form.categories, id: \.key) { entry in Text(verbatim: form.options.name(of: entry.key)).tag(entry.key) }
        } label: {
          Text("Category", tableName: "Money")
        }
        LocalDatePicker(title: Text("Date", tableName: "Money"), date: $form.occurredOn, earliest: nil, latest: form.latestDate)
      } footer: {
        if form.isEditing, let preview = form.preview(locale: locale) { Text(verbatim: preview) }
      }
      if let pick = form.budget {
        BudgetChipSection(
          pick: Binding(get: { form.budget ?? pick }, set: { form.budget = $0 }), currency: form.currency, date: form.occurredOn,
          subscriptionOverride: form.subscriptionOverride)
      }
      if form.options.savings != nil {
        SavingsDrawSection(form: form)
      }
      Section {
        TextField(text: $form.note, prompt: Text("What was it for?", tableName: "Money")) { Text("Note", tableName: "Money") }
        TextField(text: $form.merchant, prompt: Text("Optional", tableName: "Money")) { Text("Merchant", tableName: "Money") }
      }
      ReceiptFormSection(form: form)
    }
    .formStyle(.grouped)
    .disabled(form.isSaving)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          requestDismiss()
        } label: {
          Text("Cancel", tableName: "Money")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { if await form.save() != nil { dismiss() } }
        } label: {
          form.isEditing ? Text("Save changes", tableName: "Money") : Text("Save expense", tableName: "Money")
        }
        .disabled(!form.canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
    .navigationBarBackButtonHidden(dismissGuard.hasUnsavedChanges)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard this expense?", tableName: "Money"), discardTitle: Text("Discard", tableName: "Money"),
      keepEditingTitle: Text("Keep editing", tableName: "Money"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSaving) { dismissGuard.isBusy = form.isSaving }
    .onChange(of: form.amountText) { form.edited() }
    .onChange(of: form.rateText) { form.edited() }
    .onChange(of: form.fromSavingsText) { form.edited() }
    .onChange(of: form.goal) { form.edited() }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }
}

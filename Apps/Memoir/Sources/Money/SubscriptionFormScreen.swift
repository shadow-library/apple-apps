import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// Adds a subscription, or edits or deletes one, once its record and the form's options have been read.
struct SubscriptionFormScreen: View {
  let editing: UUID?
  let context: MemoirScreenContext
  @State private var form: SubscriptionForm?
  @State private var loadFailure: PresentedError?
  @State private var isGone = false
  @Environment(\.locale) private var locale

  var body: some View {
    Group {
      if let form {
        SubscriptionFormFields(form: form)
      } else if isGone {
        ShadowContentUnavailable(
          Text("That subscription is no longer here", tableName: "Money"), systemImage: "repeat",
          message: Text("It may have been deleted on another device.", tableName: "Money"))
      } else if let loadFailure {
        ShadowContentUnavailable(Text(verbatim: loadFailure.headline), kind: .error, message: loadFailure.detail.map { Text(verbatim: $0) })
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(editing == nil ? Text("Add subscription", tableName: "Money") : Text("Subscription", tableName: "Money"))
    .shadowScreen(.pushed)
    .task { await load() }
  }

  private func load() async {
    guard form == nil else { return }
    do {
      guard let editing else {
        form = SubscriptionForm(options: try await MoneyOptions.load(context), context: context, locale: locale)
        return
      }
      form = try await SubscriptionForm.load(editing, context: context, locale: locale)
      isGone = form == nil
    } catch {
      loadFailure = MoneyErrors.read(error)
    }
  }
}

private struct SubscriptionFormFields: View {
  @Bindable var form: SubscriptionForm
  @State private var dismissGuard = ShadowDismissGuard()
  @State private var isConfirmingDelete = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  var body: some View {
    Form {
      if let failure = form.failure {
        Section { ShadowValidationMessage(failure.text) }
      }
      if form.isReadOnly {
        Section {
          ShadowCallout(
            Text("This subscription was set up in a newer version of Memoir", tableName: "Money"),
            message: Text("Update the app to change it.", tableName: "Money"), intent: .warning)
        }
      }
      Section {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          TextField(text: $form.name, prompt: Text("Streaming, gym, cloud storage…", tableName: "Money")) { Text("Name", tableName: "Money") }
          if let issue = form.nameIssue { ShadowValidationMessage(Text(verbatim: issue)) }
        }
        MoneyAmountField(text: $form.amountText, currency: form.currency, issue: form.amountIssue)
        Picker(selection: $form.currency) {
          ForEach(form.currencies, id: \.self) { code in Text(verbatim: MoneyText.currencyName(code, locale: locale)).tag(code) }
        } label: {
          Text("Currency", tableName: "Money")
        }
      }
      .disabled(form.isReadOnly)
      Section {
        Picker(selection: $form.frequency) {
          ForEach(SubscriptionForm.frequencies, id: \.self) { frequency in Text(verbatim: MoneyLabels.frequency(frequency)).tag(frequency) }
        } label: {
          Text("Frequency", tableName: "Money")
        }
        if form.frequency == .custom {
          Stepper(value: $form.customIntervalDays, in: SubscriptionForm.customDays) {
            Text("Every \(form.customIntervalDays) days", tableName: "Money")
          }
        }
        LocalDatePicker(title: Text("Next due date", tableName: "Money"), date: $form.nextDue, earliest: form.earliestDue, latest: nil)
        if let issue = form.dueIssue { ShadowValidationMessage(Text(verbatim: issue)) }
        Picker(selection: $form.category) {
          ForEach(form.categories, id: \.key) { entry in Text(verbatim: form.options.name(of: entry.key)).tag(entry.key) }
        } label: {
          Text("Category", tableName: "Money")
        }
      }
      .disabled(form.isReadOnly)
      Section {
        Toggle(isOn: $form.reminderEnabled) { Text("Remind me", tableName: "Money") }
        if form.reminderEnabled {
          Picker(selection: $form.reminderLead) {
            ForEach(SubscriptionReminderLead.allCases, id: \.self) { lead in Text(verbatim: MoneyLabels.reminderLead(lead)).tag(lead) }
          } label: {
            Text("When", tableName: "Money")
          }
        }
      } footer: {
        Text("Nothing is ever charged for you — each cycle waits for your confirmation.", tableName: "Money")
      }
      .disabled(form.isReadOnly)
      if form.isEditing {
        Section {
          Button(role: .destructive) {
            isConfirmingDelete = true
          } label: {
            Text("Delete subscription", tableName: "Money")
          }
        }
      }
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
          form.isEditing ? Text("Save changes", tableName: "Money") : Text("Save subscription", tableName: "Money")
        }
        .disabled(!form.canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
    .confirmationDialog(Text("Delete this subscription?", tableName: "Money"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { if await form.delete() { dismiss() } }
      } label: {
        Text("Delete subscription", tableName: "Money")
      }
      .shadowDestructiveDialogAction()
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Money")
      }.shadowDialogCancelAction()
    } message: {
      Text("Its confirmed charges stay in Money as expenses.", tableName: "Money")
    }
    .navigationBarBackButtonHidden(dismissGuard.hasUnsavedChanges)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Money"), discardTitle: Text("Discard", tableName: "Money"),
      keepEditingTitle: Text("Keep editing", tableName: "Money"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSaving) { dismissGuard.isBusy = form.isSaving }
    .onChange(of: form.amountText) { form.edited() }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }
}

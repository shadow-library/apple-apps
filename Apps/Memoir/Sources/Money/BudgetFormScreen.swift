import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Adds a budget, or edits or deletes one, once the form's options have been read.
struct BudgetFormScreen: View {
  let editing: UUID?
  let context: MemoirScreenContext
  @State private var form: BudgetForm?
  @State private var loadFailure: PresentedError?
  @State private var isGone = false
  @State private var noCurrency = false
  @Environment(\.locale) private var locale

  var body: some View {
    Group {
      if let form {
        BudgetFormFields(form: form)
      } else if isGone {
        ShadowContentUnavailable(
          Text("That budget is no longer here", tableName: "Money"), systemImage: "chart.pie",
          message: Text("It may have been deleted on another device.", tableName: "Money"))
      } else if noCurrency {
        ShadowContentUnavailable(
          Text("No base currency yet", tableName: "Money"), systemImage: "chart.pie",
          message: Text("Money totals are kept in your base currency. Choose it in Settings, under Day and money.", tableName: "Money"))
      } else if let loadFailure {
        ShadowContentUnavailable(Text(verbatim: loadFailure.headline), kind: .error, message: loadFailure.detail.map { Text(verbatim: $0) })
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(title)
    .shadowScreen(.pushed)
    .task { await load() }
  }

  private var title: Text {
    guard editing != nil else { return Text("Add budget", tableName: "Money") }
    return Text("Budget", tableName: "Money")
  }

  private func load() async {
    guard form == nil else { return }
    do {
      guard let options = try await BudgetFormOptions.load(context) else {
        noCurrency = true
        return
      }
      guard let editing else {
        form = BudgetForm(options: options, context: context, locale: locale)
        return
      }
      guard let budget = options.standings.standing(of: editing)?.budget else {
        isGone = true
        return
      }
      form = BudgetForm(editing: budget, options: options, context: context, locale: locale)
    } catch {
      loadFailure = MoneyErrors.read(error)
    }
  }
}

private struct BudgetFormFields: View {
  @Bindable var form: BudgetForm
  @State private var dismissGuard = ShadowDismissGuard()
  @State private var isConfirmingDelete = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  var body: some View {
    Form {
      if let failure = form.failure {
        Section { ShadowValidationMessage(failure.text) }
      }
      if form.canChangeKindAndCurrency {
        Section {
          Picker(selection: $form.kind) {
            Text("Trip", tableName: "Money").tag(BudgetForm.Kind.trip)
            Text("Monthly", tableName: "Money").tag(BudgetForm.Kind.monthly)
          } label: {
            Text("Kind", tableName: "Money")
          }
          .pickerStyle(.segmented)
        } footer: {
          kindFooter
        }
      }
      Section {
        if form.isHome {
          LabeledContent {
            Text(verbatim: BudgetCopy.home)
          } label: {
            Text("Name", tableName: "Money")
          }
        } else {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            TextField(text: $form.name, prompt: namePrompt) { Text("Name", tableName: "Money") }
            if let issue = form.nameIssue { ShadowValidationMessage(Text(verbatim: issue)) }
          }
        }
        if form.isMonthlyUnavailable {
          NavigationLink(value: MemoirRoute.settings(.currencies)) { Text("Turn on another currency", tableName: "Money") }
        } else {
          Picker(selection: Binding(get: { form.currency }, set: { form.select($0) })) {
            ForEach(form.currencies, id: \.self) { code in Text(verbatim: MoneyText.currencyName(code, locale: locale)).tag(code) }
          } label: {
            Text("Currency", tableName: "Money")
          }
          .disabled(!form.canChangeKindAndCurrency)
        }
      } footer: {
        if !form.canChangeKindAndCurrency {
          Text("A budget keeps its currency and kind. To use another, add a new budget.", tableName: "Money")
        }
      }
      if form.kind == .trip {
        Section {
          LocalDatePicker(title: Text("First day", tableName: "Money"), date: $form.from, earliest: form.earliestStart, latest: nil)
            .disabled(form.isStartFixed)
          LocalDatePicker(title: Text("Last day", tableName: "Money"), date: $form.through, earliest: form.from, latest: nil)
          if let issue = form.datesIssue { ShadowValidationMessage(Text(verbatim: issue)) }
        } header: {
          Text("Dates", tableName: "Money")
        } footer: {
          if form.isStartFixed {
            Text("The trip has started, so it keeps its first day.", tableName: "Money")
          } else {
            Text("A trip can start up to \(BudgetEdits.tripBackdatingDays) days before today.", tableName: "Money")
          }
        }
      }
      Section {
        MoneyAmountField(text: $form.limitText, currency: form.currency, issue: form.limitIssue, label: Text("Limit", tableName: "Money"))
        if let note = form.limitNote {
          let refused = form.refusal != nil
          Text(verbatim: note).shadowFont(.footnote).foregroundStyle(refused ? ShadowColor.dangerText : ShadowColor.textSecondary)
        }
      } header: {
        Text("Limit", tableName: "Money")
      } footer: {
        limitFooter
      }
      Section {
        MoneyAmountField(text: $form.oneOffText, currency: form.currency, issue: form.oneOffIssue, label: Text("One-off from", tableName: "Money"))
        if let note = form.thresholdNote { Text(verbatim: note).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
      } header: {
        Text("One-off purchases", tableName: "Money")
      } footer: {
        if let current = form.currentThreshold {
          Text("A purchase at least this big counts as a one-off, which may be paid from savings. Leave it empty for the automatic threshold, now \(current).", tableName: "Money")
        } else {
          Text("A purchase at least this big counts as a one-off, which may be paid from savings. Leave it empty for the automatic threshold.", tableName: "Money")
        }
      }
      if form.isEditing && !form.isHome {
        Section {
          Button(role: .destructive) {
            isConfirmingDelete = true
          } label: {
            Text("Delete budget", tableName: "Money")
          }
        }
      }
    }
    .formStyle(.grouped)
    .disabled(form.isSaving)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          if dismissGuard.requestDismiss() { dismiss() }
        } label: {
          Text("Cancel", tableName: "Money")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { if await form.save() != nil { dismiss() } }
        } label: {
          form.isEditing ? Text("Save changes", tableName: "Money") : Text("Save budget", tableName: "Money")
        }
        .disabled(!form.canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
    .confirmationDialog(Text("Delete this budget?", tableName: "Money"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { if await form.delete() { dismiss() } }
      } label: {
        Text("Delete budget", tableName: "Money")
      }
      .shadowDestructiveDialogAction()
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Money")
      }.shadowDialogCancelAction()
    } message: {
      Text("Its expenses go back to counting in Home or the monthly budget of their currency, months not yet closed included.", tableName: "Money")
    }
    .navigationBarBackButtonHidden(dismissGuard.hasUnsavedChanges)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Money"), discardTitle: Text("Discard", tableName: "Money"),
      keepEditingTitle: Text("Keep editing", tableName: "Money"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSaving) { dismissGuard.isBusy = form.isSaving }
    .onChange(of: form.limitText) { form.edited() }
    .onChange(of: form.oneOffText) { form.edited() }
  }

  private var namePrompt: Text {
    form.kind == .trip ? Text("Lisbon in May", tableName: "Money") : Text("Spending in kroner", tableName: "Money")
  }

  @ViewBuilder
  private var kindFooter: some View {
    switch form.kind {
    case .trip:
      Text("Everything dated within the trip counts here, whatever its currency.", tableName: "Money")
    case .monthly where form.isMonthlyUnavailable:
      Text("Every currency you use already has a monthly budget. Turn on another currency in Settings to add one.", tableName: "Money")
    case .monthly:
      Text("Expenses in its currency count here every month. Home counts everything else.", tableName: "Money")
    }
  }

  @ViewBuilder
  private var limitFooter: some View {
    switch form.kind {
    case .monthly:
      Text("Lowering a limit counts at once. Raising it waits for next month, unless it goes back up to the limit the month started with.", tableName: "Money")
    case .trip where form.currency != form.options.home:
      Text("Spending in other currencies converts through \(form.options.home.code) at each day’s rate; until a rate is known, it’s counted apart.", tableName: "Money")
    case .trip:
      Text("Once the trip has started, its limit can only go down.", tableName: "Money")
    }
  }
}

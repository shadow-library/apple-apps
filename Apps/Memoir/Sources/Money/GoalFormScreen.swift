import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// Adds a goal or edits one, once savings have been read for the home currency and the account's day.
struct GoalFormScreen: View {
  let editing: UUID?
  let context: MemoirScreenContext
  @State private var form: GoalForm?
  @State private var standing = Standing.loading
  @Environment(\.locale) private var locale

  private enum Standing: Equatable {
    case loading
    case noCurrency
    case gone
    case full
    case failed(PresentedError)
  }

  var body: some View {
    Group {
      if let form {
        GoalFormFields(form: form)
      } else {
        switch standing {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noCurrency: GoalsNoCurrency()
        case .gone:
          ShadowContentUnavailable(
            Text("That goal is no longer here", tableName: "Money"), systemImage: "star.circle",
            message: Text("It may have been deleted on another device.", tableName: "Money"))
        case .full:
          ShadowContentUnavailable(
            Text("Three goals are filling", tableName: "Money"), systemImage: "star.circle",
            message: Text(verbatim: GoalCopy.limit(SavingsRules.maximumActiveGoals)))
        case .failed(let error):
          ShadowContentUnavailable(Text(verbatim: error.headline), kind: .error, message: error.detail.map { Text(verbatim: $0) })
        }
      }
    }
    .navigationTitle(editing == nil ? Text("Add goal", tableName: "Money") : Text("Edit goal", tableName: "Money"))
    .shadowScreen(.pushed)
    .task { await load() }
  }

  private func load() async {
    guard form == nil else { return }
    do {
      let clock = context.clock
      guard let snapshot = try await context.stores.main.read({ transaction in try SavingsSnapshot.load(in: transaction, clock: clock) }) else {
        standing = .noCurrency
        return
      }
      guard let editing else {
        guard snapshot.canAddGoal else {
          standing = .full
          return
        }
        form = GoalForm(home: snapshot.home, today: snapshot.overview.today, context: context, locale: locale)
        return
      }
      guard let goal = snapshot.goal(editing) else {
        standing = .gone
        return
      }
      form = GoalForm(editing: goal, home: snapshot.home, today: snapshot.overview.today, context: context, locale: locale)
    } catch {
      standing = .failed(MoneyErrors.read(error))
    }
  }
}

private struct GoalFormFields: View {
  @Bindable var form: GoalForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      if let failure = form.failure {
        Section { ShadowValidationMessage(failure.text) }
      }
      Section {
        TextField(text: $form.name, prompt: Text("New bike", tableName: "Money")) { Text("Name", tableName: "Money") }
      }
      Section {
        GoalSymbolPicker(symbols: form.symbols, selection: $form.symbol)
      } header: {
        Text("Symbol", tableName: "Money")
      }
      Section {
        MoneyAmountField(text: $form.targetText, currency: form.currency, issue: form.targetIssue, label: Text("Target", tableName: "Money"))
        Toggle(isOn: $form.hasTargetDate) { Text("Target date", tableName: "Money") }
        if form.hasTargetDate {
          LocalDatePicker(title: Text("By", tableName: "Money"), date: $form.targetDate, earliest: form.today, latest: nil)
        }
      } header: {
        Text("Target", tableName: "Money")
      } footer: {
        if form.canChangeTarget {
          Text(
            "In \(form.currency.code). Savings fill your goals in order, after paying back anything borrowed. A date shows what it needs each month to arrive on time.",
            tableName: "Money")
        } else {
          Text("This goal is no longer filling, so its target and date stay as they were.", tableName: "Money")
        }
      }
      .disabled(!form.canChangeTarget)
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
          form.isEditing ? Text("Save changes", tableName: "Money") : Text("Save goal", tableName: "Money")
        }
        .disabled(!form.canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
    .navigationBarBackButtonHidden(dismissGuard.hasUnsavedChanges)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Money"), discardTitle: Text("Discard", tableName: "Money"),
      keepEditingTitle: Text("Keep editing", tableName: "Money"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSaving) { dismissGuard.isBusy = form.isSaving }
    .onChange(of: form.targetText) { form.edited() }
    .onChange(of: form.name) { form.edited() }
  }
}

/// The goal's symbol from a small set, each one named for VoiceOver.
private struct GoalSymbolPicker: View {
  let symbols: [String]
  @Binding var selection: String

  var body: some View {
    ShadowFlowLayout(spacing: Spacing.space2) {
      ForEach(symbols, id: \.self) { symbol in
        let isSelected = symbol == selection
        Button {
          selection = symbol
        } label: {
          Image(systemName: symbol)
            .imageScale(.large)
            .frame(minWidth: Spacing.space10, minHeight: Spacing.space10)
            .foregroundStyle(isSelected ? ShadowColor.onAccent : ShadowColor.textPrimary)
            .background(isSelected ? ShadowColor.accent : ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: GoalCopy.symbolName(symbol)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(.vertical, Spacing.space1)
  }
}

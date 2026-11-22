import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quick-logs/meals-screen.tsx`: today's meals, a meal typed or taken from a preset, and the last 14 days of calories.
struct MealsView: View {
  @State private var model: MealsModel
  @State private var isAddingMeal = false
  @State private var editingPreset: PresetEditing?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: MealsModel(context: context))
  }

  var body: some View {
    LogLoadable(state: model.overview.state, failureTitle: Text("Meals couldn’t be loaded", tableName: "Log")) { overview in
      ScrollView {
        ShadowAdaptiveColumns {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            today(overview)
            history(overview)
          }
          presets(overview)
        }
        .padding(Spacing.space4)
      }
    }
    .navigationTitle(Text("Meals", tableName: "Log"))
    .shadowScreen(.pushed)
    .task { await model.observe() }
    .task(id: model.confirmingPreset) {
      guard model.confirmingPreset != nil else { return }
      try? await Task.sleep(for: MealsModel.relogConfirm)
      model.endConfirm()
    }
    .sheet(isPresented: $isAddingMeal) { MealEntrySheet(model: model, presets: model.overview.state.value?.presets.map(\.preset) ?? []) }
    .sheet(item: $editingPreset) { editing in MealPresetSheet(model: model, existing: editing.preset) }
  }

  private func today(_ overview: MealsOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HStack {
          Group {
            if overview.meals.isEmpty {
              Text("Today", tableName: "Log")
            } else {
              Text("Today · \(LogFormat.calories(overview.totalCalories))", tableName: "Log")
            }
          }
          .shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Spacer()
          Button {
            isAddingMeal = true
          } label: {
            Text("Add meal", tableName: "Log")
          }
          .buttonStyle(.shadowFilled)
          .keyboardShortcut("n", modifiers: .command)
        }
        if overview.meals.isEmpty {
          ShadowContentUnavailable(
            Text("Nothing logged today", tableName: "Log"), message: Text("A blank day stays blank — it is not a zero, and it costs nothing.", tableName: "Log"))
        }
        ForEach(overview.meals, id: \.id) { meal in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              Text(verbatim: meal.name).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
              Text(verbatim: mealMeta(meal)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
            Spacer()
            Text(verbatim: LogFormat.calories(meal.calories)).shadowFont(.body).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
          }
          .accessibilityElement(children: .combine)
        }
        LogSaveFeedback(failureTitle: Text("Not saved", tableName: "Log"), failure: model.failure, confirmation: model.confirmation)
        EntryCapNote(advisory: model.advisory)
      }
    }
  }

  private func mealMeta(_ meal: MealRecord) -> String {
    let time = LogFormat.time(millis: meal.loggedAtMillis, in: model.context.clock.deviceZone())
    let source = meal.preset == nil ? String(localized: "Typed", table: "Log") : String(localized: "Preset", table: "Log")
    return "\(time) · \(source) · \(LogFormat.mealType(meal.mealType))"
  }

  private func history(_ overview: MealsOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Last 14 days", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        LogDayChart(LogDayChart.Point.points(overview.calories) { Double($0) }, label: Text("Calories over the last 14 days", tableName: "Log")) {
          Text(verbatim: LogFormat.calories(Int($0)))
        }
        Group {
          if let average = overview.averageCalories {
            Text("Average \(LogFormat.calories(average))", tableName: "Log")
          } else {
            Text("Nothing logged", tableName: "Log")
          }
        }
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        ForEach(overview.calories.reversed(), id: \.date) { day in
          HStack {
            Text(verbatim: LogFormat.day(day.date, today: overview.date)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            Spacer()
            if let calories = day.value {
              Text(verbatim: LogFormat.calories(calories)).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
            } else {
              Text("Nothing logged — blank, not zero", tableName: "Log").shadowFont(.subheadline).foregroundStyle(ShadowColor.textTertiary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func presets(_ overview: MealsOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HStack {
          Text("Presets", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Spacer()
          Button {
            editingPreset = PresetEditing(preset: nil)
          } label: {
            Text("New preset", tableName: "Log")
          }
          .buttonStyle(.shadowBordered)
        }
        if overview.presets.isEmpty {
          Text("No presets on this account yet. Meals you type still log in one step with Add meal.", tableName: "Log")
            .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        } else {
          ForEach(overview.presets, id: \.preset.id) { usage in
            HStack(spacing: Spacing.space3) {
              VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(verbatim: usage.preset.name).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
                Text("Used \(usage.usageCount) times", tableName: "Log").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
              }
              Spacer()
              Text(verbatim: LogFormat.calories(usage.preset.calories)).shadowFont(.body).monospacedDigit()
              Menu {
                Button {
                  editingPreset = PresetEditing(preset: usage.preset)
                } label: {
                  Label {
                    Text("Edit preset", tableName: "Log")
                  } icon: {
                    Image(systemName: "pencil")
                  }
                }
                Button(role: .destructive) {
                  Task { await model.deletePreset(usage.preset) }
                } label: {
                  Label {
                    Text("Delete preset", tableName: "Log")
                  } icon: {
                    Image(systemName: "trash")
                  }
                }
              } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel(Text("More for \(usage.preset.name)", tableName: "Log"))
              }
              .menuStyle(.borderlessButton)
              .fixedSize()
            }
          }
          PresetChips(model: model, presets: Array(overview.presets.prefix(4).map(\.preset)))
          Text("A logged meal keeps the numbers it was logged with. Editing a preset later never changes a past meal.", tableName: "Log")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }
}

private struct PresetEditing: Identifiable {
  let preset: MealPresetRecord?

  var id: UUID? { preset?.id }
}

/// One tap logs a preset's meal; the same preset again within moments asks for a second tap (`relogPrompt`).
struct PresetChips: View {
  let model: MealsModel
  let presets: [MealPresetRecord]
  var logged: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowFlowLayout {
        ForEach(presets, id: \.id) { preset in
          Button {
            Task { if await model.logPreset(preset) == .logged { logged() } }
          } label: {
            Text(verbatim: "\(preset.name) · \(LogFormat.calories(preset.calories))")
          }
          .buttonStyle(model.confirmingPreset == preset.id ? .shadowFilled : .shadowBordered)
          .disabled(model.loggingPreset != nil)
        }
      }
      if let confirming = presets.first(where: { $0.id == model.confirmingPreset }) {
        Text("Just logged. Select \(confirming.name) again to log a second one.", tableName: "Log")
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

/// `meal-entry-panel.tsx`: what it was, its calories and its kind, with the presets beside them.
struct MealEntrySheet: View {
  @Bindable var model: MealsModel
  let presets: [MealPresetRecord]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        MealDraftFields(draft: $model.draft, namePrompt: Text("Oats, berries, skyr", tableName: "Log"))
        if let failure = model.failure { ShadowCallout(Text("Meal not saved", tableName: "Log"), message: failure.text, intent: .danger) }
        EntryCapNote(advisory: model.advisory)
        if !presets.isEmpty {
          Text("Your presets", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          PresetChips(model: model, presets: presets) { dismiss() }
        }
      }
      .padding(Spacing.space4)
    }
    .shadowSheetStyle(.form)
    .shadowSheetHeader(
      Text("Add meal", tableName: "Log"), cancel: ShadowSheetCancel(Text("Cancel", tableName: "Log")) { dismiss() },
      confirm: ShadowSheetConfirm(Text("Save meal", tableName: "Log"), isDisabled: !model.canSaveMeal, submitShortcut: true) {
        Task { if await model.saveMeal() { dismiss() } }
      })
  }
}

struct MealPresetSheet: View {
  let model: MealsModel
  let existing: MealPresetRecord?
  @State private var draft: MealDraft
  @Environment(\.dismiss) private var dismiss

  init(model: MealsModel, existing: MealPresetRecord?) {
    self.model = model
    self.existing = existing
    _draft = State(initialValue: existing.map(MealDraft.init) ?? MealDraft())
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        MealDraftFields(draft: $draft, namePrompt: Text("Porridge", tableName: "Log"))
        if let failure = model.failure { ShadowCallout(Text("Preset not saved", tableName: "Log"), message: failure.text, intent: .danger) }
      }
      .padding(Spacing.space4)
    }
    .shadowSheetStyle(.form)
    .shadowSheetHeader(
      existing == nil ? Text("New preset", tableName: "Log") : Text("Edit preset", tableName: "Log"),
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "Log")) { dismiss() },
      confirm: ShadowSheetConfirm(Text("Save preset", tableName: "Log"), isDisabled: !draft.isComplete || model.isSaving, submitShortcut: true) {
        Task { if await model.savePreset(draft, editing: existing) { dismiss() } }
      })
  }
}

private struct MealDraftFields: View {
  @Binding var draft: MealDraft
  let namePrompt: Text

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      TextField(text: $draft.name, prompt: namePrompt) { Text("What was it", tableName: "Log") }
        .shadowField()
      VStack(alignment: .leading, spacing: Spacing.space1) {
        TextField(value: $draft.calories, format: .number) { Text("Calories", tableName: "Log") }
          .shadowField()
          #if os(iOS)
            .keyboardType(.numberPad)
          #endif
          .shadowValidation(draft.touched ? draft.caloriesProblem.map { Text(verbatim: $0) } : nil)
          .onChange(of: draft.calories) { draft.touched = true }
        Text("Your estimate. Zero is a valid answer.", tableName: "Log").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      Picker(selection: $draft.mealType) {
        ForEach(MealType.allCases, id: \.self) { type in Text(verbatim: LogFormat.mealType(.known(type))).tag(type) }
      } label: {
        Text("Kind", tableName: "Log")
      }
      .pickerStyle(.segmented)
    }
  }
}

#Preview {
  NavigationStack {
    if let context = try? MemoirScreenContext.inMemory() { MealsView(context: context) }
  }
}

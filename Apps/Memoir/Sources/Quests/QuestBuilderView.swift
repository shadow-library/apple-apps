import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quests/quest-builder-screen.tsx`: three decisions (what it is, when it happens, how strict), with the week it would make beside them.
struct QuestBuilderView: View {
  @State private var model: QuestBuilderModel
  @Environment(\.dismiss) private var dismiss
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?

  init(mode: QuestBuilderMode, context: MemoirScreenContext) {
    _model = State(initialValue: QuestBuilderModel(mode: mode, context: context))
  }

  var body: some View {
    content
      .navigationTitle(model.isEditing ? Text("Edit quest", tableName: "Quests") : Text("New quest", tableName: "Quests"))
      .shadowScreen(.pushed)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { if await model.save() != nil { dismiss() } }
          } label: {
            model.isEditing ? Text("Save changes", tableName: "Quests") : Text("Create quest", tableName: "Quests")
          }
          .disabled(!model.canSave)
          .keyboardShortcut("s", modifiers: .command)
        }
      }
      .task { await model.load() }
      .task(id: model.draft) { await model.observePreview() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("This quest couldn’t be loaded", tableName: "Quests"), kind: .error, message: error.text)
    case .missing:
      ShadowContentUnavailable(
        Text("This quest isn’t here", tableName: "Quests"), kind: .noResults, message: Text("It may have been removed, or the link is wrong.", tableName: "Quests")
      ) {
        Button {
          dismiss()
        } label: {
          Text("Back to Quests", tableName: "Quests")
        }.buttonStyle(.shadowBordered)
      }
    case .ready:
      ScrollView {
        ShadowAdaptiveColumns {
          form
          aside
        }
        .padding(Spacing.space4)
      }
    }
  }

  private var form: some View {
    @Bindable var model = model
    return VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowCard {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          introduction
          nameField
          QuestBuilderField(label: Text("Category", tableName: "Quests"), helper: Text("Decides which lifetime stat grows.", tableName: "Quests")) {
            Picker(selection: $model.form.statAffinity) {
              ForEach(QuestForm.statOrder, id: \.self) { stat in Text(verbatim: QuestsCopy.stat(stat)).tag(stat) }
            } label: {
              Text("Category", tableName: "Quests")
            }
            .labelsHidden()
          }
          timeField
          durationField
          strictnessField
          repeatsField
          Toggle(isOn: $model.form.threshold) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              Text("Complete from a health threshold", tableName: "Quests").shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
              thresholdDescription.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
              if model.isEditing, model.source?.threshold == nil,
                QuestThresholdReader.mayLiveElsewhere(isSyncing: sync?.runtime != nil, syncingRoutes: sync?.syncingRoutes ?? [])
              {
                Text(QuestsCopy.thresholdElsewhere).shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
              }
            }
          }
          reminderField
        }
      }
      if model.isThresholdPending {
        ShadowCallout(
          Text("Quest created, but its health threshold wasn’t saved.", tableName: "Quests"),
          message: Text("Save again to add it.", tableName: "Quests") + (model.failure.map { Text(verbatim: "\n") + $0.text } ?? Text(verbatim: "")), intent: .warning)
      } else if let failure = model.failure {
        ShadowCallout(
          model.isEditing ? Text("Changes not saved", tableName: "Quests") : Text("Quest not created", tableName: "Quests"), message: failure.text, intent: .danger)
      }
      if let issue = model.issues.first {
        blocked(issue).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private var introduction: some View {
    Group {
      if model.isEditing {
        Text("Changes apply from today on. Days already logged keep the record they were logged with.", tableName: "Quests")
      } else {
        Text("Three decisions: what it is, when it happens, and how strict you want it to be.", tableName: "Quests")
      }
    }
    .shadowFont(.subheadline)
    .foregroundStyle(ShadowColor.textSecondary)
  }

  private var nameField: some View {
    @Bindable var model = model
    let missing = model.nameTouched && model.form.trimmedName.isEmpty
    return QuestBuilderField(
      label: Text("Quest name", tableName: "Quests"),
      helper: Text("Written as a promise, not a task — “Read 20 pages” keeps better than “Read more”.", tableName: "Quests")
    ) {
      TextField(text: $model.form.name, prompt: Text("Read 20 pages", tableName: "Quests")) { Text("Quest name", tableName: "Quests") }
        .shadowField()
        .shadowValidation(missing ? Text("Give the quest a name.", tableName: "Quests") : nil)
        .onChange(of: model.form.name) { model.nameTouched = true }
    }
  }

  private var timeField: some View {
    @Bindable var model = model
    let hasTime = Binding(get: { model.form.startMinute != nil }, set: { model.form.setStartMinute($0 ? Self.standardStart : nil) })
    let time = Binding(
      get: { QuestCalendar.time(model.form.startMinute ?? Self.standardStart) }, set: { model.form.setStartMinute(QuestCalendar.minute(of: $0)) })
    return QuestBuilderField(
      label: Text("Time of day", tableName: "Quests"), helper: scheduleHelper(Text("Optional. An untimed quest is judged on the day, not the hour.", tableName: "Quests"))
    ) {
      HStack(spacing: Spacing.space3) {
        Toggle(isOn: hasTime) { Text("At a set time", tableName: "Quests") }
        if model.values.startMinute != nil {
          DatePicker(selection: time, displayedComponents: .hourAndMinute) { Text("Time of day", tableName: "Quests") }.labelsHidden()
        }
      }
      .disabled(model.isScheduleLocked)
      if model.issues.contains(.draft(.anchorNeedsStartTime)) { ShadowValidationMessage(Text("An Anchor quest needs a start time.", tableName: "Quests")) }
    }
  }

  private var durationField: some View {
    @Bindable var model = model
    let range = DraftPreview.durationRange
    return QuestBuilderField(label: Text("Usual length", tableName: "Quests"), helper: Text("Used for the day’s load, never as a timer.", tableName: "Quests")) {
      HStack(spacing: Spacing.space3) {
        TextField(value: $model.form.durationMinutes, format: .number) { Text("Usual length in minutes", tableName: "Quests") }
          .shadowField()
          .frame(maxWidth: 120)
        Text("min", tableName: "Quests").foregroundStyle(ShadowColor.textSecondary)
        Stepper(value: $model.form.durationMinutes, in: range, step: QuestForm.durationStep) { Text("Usual length in minutes", tableName: "Quests") }
          .labelsHidden()
      }
      if model.issues.contains(where: { if case .draft(.durationOutOfRange) = $0 { true } else { false } }) {
        ShadowValidationMessage(Text("Between \(range.lowerBound) and \(range.upperBound) minutes.", tableName: "Quests"))
      }
    }
  }

  private var strictnessField: some View {
    let levels = QuestForm.builderStrictness.contains(model.values.strictness) ? QuestForm.builderStrictness : QuestForm.builderStrictness + [model.values.strictness]
    return QuestBuilderField(label: Text("Strictness", tableName: "Quests"), helper: nil) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.space3)], spacing: Spacing.space3) {
        ForEach(levels, id: \.self) { level in
          let selected = model.values.strictness == level
          Button {
            model.form.strictness = level
          } label: {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              Text(verbatim: QuestsCopy.strictness(level)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
              Text(verbatim: QuestsCopy.strictnessRule(level)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.space3)
            .background(selected ? ShadowColor.accentSoft : ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(selected ? ShadowColor.accent : ShadowColor.borderSubtle))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .disabled(model.isScheduleLocked)
    }
  }

  private var repeatsField: some View {
    @Bindable var model = model
    let editable = !model.isScheduleLocked && model.fixedRecurrence == nil
    let interval = DraftPreview.intervalRange
    return QuestBuilderField(label: Text("Repeats", tableName: "Quests"), helper: repeatsHelper) {
      if model.fixedRecurrence == nil {
        Picker(selection: $model.form.repeats) {
          Text("Days of week", tableName: "Quests").tag(QuestRepeat.weekly)
          Text("Every N days", tableName: "Quests").tag(QuestRepeat.everyNDays)
        } label: {
          Text("Repeats", tableName: "Quests")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!editable)
        switch model.values.repeats {
        case .everyNDays:
          HStack(spacing: Spacing.space3) {
            TextField(value: $model.form.interval, format: .number) { Text("Repeat every N days", tableName: "Quests") }
              .shadowField()
              .frame(maxWidth: 120)
            Stepper(value: $model.form.interval, in: interval) { Text("Repeat every N days", tableName: "Quests") }.labelsHidden()
          }
          .disabled(!editable)
        case .weekly:
          ShadowFlowLayout {
            ForEach(QuestCalendar.week(from: .monday), id: \.self) { day in
              ShadowTag(Text(verbatim: QuestsCopy.weekday(day)), isSelected: weekdayBinding(day))
            }
          }
          .disabled(!editable)
        }
        if model.issues.contains(.noWeekdays) { ShadowValidationMessage(Text("Pick at least one day.", tableName: "Quests")) }
        if model.issues.contains(where: { if case .draft(.intervalOutOfRange) = $0 { true } else { false } }) {
          ShadowValidationMessage(Text("Repeat every \(interval.lowerBound) to \(interval.upperBound) days.", tableName: "Quests"))
        }
      }
    }
  }

  private func weekdayBinding(_ day: LocalDate.Weekday) -> Binding<Bool> {
    Binding(
      get: { model.form.weekdays.contains(day) },
      set: { isOn in
        if isOn { model.form.weekdays.insert(day) } else { model.form.weekdays.remove(day) }
      })
  }

  /// `repeatsHelper` (`quest-builder-screen.tsx:168-175`).
  private var repeatsHelper: Text {
    let interval = DraftPreview.intervalRange
    if let block = lockReason { return Text(verbatim: block) }
    if let fixed = model.fixedRecurrence {
      return Text("\(QuestsCopy.recurrence(RecurrenceSummary(fixed))) — this schedule can’t be changed here.", tableName: "Quests")
    }
    guard model.values.repeats == .everyNDays else { return Text("Six days a week is the pattern most people keep.", tableName: "Quests") }
    guard model.isEditing, let start = model.source?.quest.recurrence.startDate else {
      return Text("Counted from today, every \(interval.lowerBound) to \(interval.upperBound) days.", tableName: "Quests")
    }
    return Text("Counted from \(QuestsCopy.shortDate(start)), every \(interval.lowerBound) to \(interval.upperBound) days.", tableName: "Quests")
  }

  private var lockReason: String? {
    guard case .unavailable(let block) = model.scheduleEdit else { return nil }
    return QuestsCopy.block(block)
  }

  private func scheduleHelper(_ helper: Text) -> Text {
    lockReason.map { Text(verbatim: $0) } ?? helper
  }

  private var thresholdDescription: Text {
    let label = model.thresholdShown.map(QuestsCopy.threshold) ?? ""
    return Text("\(label). When a logged metric passes it, Memoir offers to complete this quest. It never completes it for you.", tableName: "Quests")
  }

  private var reminderField: some View {
    @Bindable var model = model
    let timed = model.values.startMinute != nil
    return QuestBuilderField(
      label: Text("Reminder", tableName: "Quests"),
      helper: timed ? nil : Text("A reminder needs a time of day.", tableName: "Quests")
    ) {
      Toggle(isOn: $model.form.reminderEnabled) { Text("Remind me before it starts", tableName: "Quests") }
        .disabled(!timed)
      if timed && model.form.reminderEnabled {
        Picker(selection: $model.form.reminderLeadMinutes) {
          ForEach(QuestForm.reminderLeads, id: \.self) { lead in
            if lead == 0 {
              Text("At the start", tableName: "Quests").tag(lead)
            } else {
              Text("\(QuestsCopy.duration(lead)) before", tableName: "Quests").tag(lead)
            }
          }
        } label: {
          Text("When", tableName: "Quests")
        }
      }
    }
  }

  @ViewBuilder
  private var aside: some View {
    if model.scheduleEdit == .unavailable(.questInactive) {
      ShadowCallout(
        Text("This quest is kept as history", tableName: "Quests"),
        message: Text("Its time of day, repeats and strictness stay as they were. Name, category and usual length can change.", tableName: "Quests"), intent: .info)
    } else if model.isScheduleLocked {
      ShadowCallout(
        Text("Schedule and strictness are read-only today", tableName: "Quests"),
        message: Text(
          "Today’s plan is locked, so the time of day, repeats and strictness can’t change until tomorrow. Name, category and usual length can.", tableName: "Quests"),
        intent: .info)
    } else if let preview = model.preview {
      QuestWeekEffect(preview: preview, interval: model.values.interval)
    }
  }

  private func blocked(_ issue: QuestFormIssue) -> Text {
    let interval = DraftPreview.intervalRange
    let duration = DraftPreview.durationRange
    return switch issue {
    case .draft(.nameRequired): Text("Give the quest a name.", tableName: "Quests")
    case .noWeekdays: Text("Pick at least one day.", tableName: "Quests")
    case .draft(.intervalOutOfRange): Text("Repeat every \(interval.lowerBound) to \(interval.upperBound) days.", tableName: "Quests")
    case .draft(.anchorNeedsStartTime): Text("An Anchor quest needs a start time.", tableName: "Quests")
    case .draft(.startMinuteOutOfRange): Text("Pick a time within the day.", tableName: "Quests")
    case .draft(.durationOutOfRange):
      Text("Usual length must be between \(duration.lowerBound) and \(duration.upperBound) minutes.", tableName: "Quests")
    case .unchanged: Text("Nothing has changed yet.", tableName: "Quests")
    }
  }

  private static let standardStart = 9 * 60
}

private struct QuestBuilderField<Content: View>: View {
  let label: Text
  let helper: Text?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      content
      if let helper { helper.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
    }
  }
}

/// "Effect on your week" (`quest-builder-screen.tsx:497-534`, `fixture-provider.ts:608-631`).
private struct QuestWeekEffect: View {
  let preview: DraftPreview
  let interval: Int

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowCard {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          Text("Effect on your week", tableName: "Quests").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          if let cadence { cadence.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
          ForEach(preview.days) { day in
            VStack(alignment: .leading, spacing: Spacing.space1) {
              HStack {
                Text(verbatim: Self.label(day))
                Spacer()
                Group {
                  if day.isOverCapacity {
                    Text("\(QuestsCopy.duration(day.minutes)) · over capacity", tableName: "Quests")
                  } else {
                    Text(verbatim: QuestsCopy.duration(day.minutes))
                  }
                }
                .monospacedDigit()
              }
              .shadowFont(.footnote)
              .foregroundStyle(day.draftRuns ? ShadowColor.textPrimary : ShadowColor.textSecondary)
              QuestLoadBar(minutes: day.minutes)
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
      if let overload = preview.overload {
        ShadowCallout(
          Text("One day would carry more than usual", tableName: "Quests"),
          message: Text(
            "\(Self.label(overload)) would be the heaviest day — about \(QuestsCopy.duration(overload.minutes)), above your usual load. This is a note, not a limit.",
            tableName: "Quests"), intent: .warning)
      }
    }
  }

  /// `everyNDaysNote` (`fixture-provider.ts:131-134`).
  private var cadence: Text? {
    guard let runs = preview.dailyCadence else { return nil }
    let days = DraftPreview.windowDays
    return interval <= 1
      ? Text("Every day — \(runs) times in the next \(days) days.", tableName: "Quests")
      : Text("Every \(interval) days — \(runs) times in the next \(days) days.", tableName: "Quests")
  }

  /// `previewDayLabel` (`fixture-provider.ts:136-140`).
  static func label(_ day: DraftPreviewDay) -> String {
    switch day.offset {
    case 0: String(localized: "Today", table: "Quests")
    case 1: String(localized: "Tomorrow", table: "Quests")
    default: QuestCalendar.date(day.date).formatted(.dateTime.weekday(.abbreviated).day())
    }
  }
}

#Preview("New quest") {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      QuestBuilderView(mode: .create, context: context)
    }
  }
}

import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct OnboardingDayStep: View {
  @Bindable var model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space5) {
      OnboardingLead(
        Text(
          "A day in Memoir runs from when you wake to when you sleep, not from midnight. Two times and a currency, and you never have to think about this again.",
          tableName: "Onboarding"))
      OnboardingField(
        label: Text("Wake time", tableName: "Onboarding"), helper: Text("Quests scheduled before this are not counted late.", tableName: "Onboarding")
      ) {
        DatePicker(selection: minute(\.wakeMinute), displayedComponents: .hourAndMinute) { Text("Wake time", tableName: "Onboarding") }.labelsHidden()
      }
      OnboardingField(
        label: Text("Sleep time", tableName: "Onboarding"),
        helper: Text("Your day closes here — logs after it still belong to today.", tableName: "Onboarding"),
        problem: model.problem.map(OnboardingCopy.problem)
      ) {
        DatePicker(selection: minute(\.sleepMinute), displayedComponents: .hourAndMinute) { Text("Sleep time", tableName: "Onboarding") }.labelsHidden()
      }
      OnboardingField(label: Text("Time zone", tableName: "Onboarding"), helper: zoneHelper) {
        NavigationLink {
          TimeZoneList(selected: model.draft.timeZone, deviceZone: model.deviceZone) { identifier in
            model.draft.timeZone = identifier
            return true
          }
        } label: {
          HStack {
            Text(verbatim: SettingsCopy.zone(model.draft.timeZone)).foregroundStyle(ShadowColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(ShadowColor.textTertiary).accessibilityHidden(true)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      OnboardingField(
        label: Text("Home currency", tableName: "Onboarding"),
        helper: Text(
          "Chosen once. Spend in another currency keeps its own and converts to this one, and this stays fixed afterwards.", tableName: "Onboarding")
      ) {
        Picker(selection: $model.draft.currency) {
          ForEach(SettingsCurrencies.supported, id: \.self) { code in Text(verbatim: SettingsCurrencies.label(code)).tag(code) }
        } label: {
          Text("Home currency", tableName: "Onboarding")
        }
        .labelsHidden()
      }
      Text(
        "Everything else here can be changed in Settings, including after a year of history. Changing your wake window never rewrites past days.",
        tableName: "Onboarding"
      )
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      OnboardingSyncLink()
    }
  }

  private var zoneHelper: Text {
    if model.draft.timeZone == model.deviceZone {
      return Text("Detected from this device. Travel will not move your day unless you change it.", tableName: "Onboarding")
    }
    return Text(
      "This device is set to \(SettingsCopy.zone(model.deviceZone)). Travel will not move your day unless you change it.", tableName: "Onboarding")
  }

  private func minute(_ path: WritableKeyPath<OnboardingDraft, Int>) -> Binding<Date> {
    Binding(get: { QuestCalendar.time(model.draft[keyPath: path]) }, set: { model.draft[keyPath: path] = QuestCalendar.minute(of: $0) })
  }
}

struct OnboardingQuestStep: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space5) {
      OnboardingLead(
        Text(
          "One quest is enough to start. Pick something you could do today even on a bad day — the point is the promise, not the size of it.",
          tableName: "Onboarding"))
      OnboardingField(
        label: Text("What is the promise?", tableName: "Onboarding"),
        helper: Text("Concrete beats ambitious: read ten pages keeps better than read more.", tableName: "Onboarding"),
        problem: model.nameTouched && model.problem == .nameRequired
          ? String(localized: "Name the promise — for example, read 10 pages.", table: "Onboarding") : nil
      ) {
        TextField(
          text: Binding(get: { model.draft.name }, set: { model.setName($0) }), prompt: Text("e.g. Read 10 pages", tableName: "Onboarding")
        ) {
          Text("What is the promise?", tableName: "Onboarding")
        }
        .shadowField()
        .onSubmit { model.advance() }
      }
      ShadowFlowLayout {
        ForEach(OnboardingCopy.examples, id: \.self) { example in
          ShadowTag(Text(verbatim: example)) { model.setName(example) }
        }
      }
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Which part of you does it grow?", tableName: "Onboarding").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.space3)], spacing: Spacing.space3) {
          ForEach(OnboardingDraft.statOrder, id: \.self) { stat in
            OnboardingChoice(isSelected: model.draft.stat == stat, action: { model.draft.stat = stat }) {
              VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(verbatim: QuestsCopy.stat(stat)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
                Text(verbatim: OnboardingCopy.statDescription(stat)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
              }
            }
          }
        }
      }
    }
  }
}

struct OnboardingScheduleStep: View {
  @Bindable var model: OnboardingModel

  var body: some View {
    let days = model.draft.orderedScheduledDays
    VStack(alignment: .leading, spacing: Spacing.space5) {
      OnboardingLead(
        Text("When should “\(model.draft.trimmedName)” come round? Most people start with fewer days than they expect to keep.", tableName: "Onboarding"))
      Picker(selection: $model.draft.recurrence) {
        Text("Every day", tableName: "Onboarding").tag(OnboardingRecurrence.daily)
        Text("Chosen days", tableName: "Onboarding").tag(OnboardingRecurrence.chosen)
        Text("Times a week", tableName: "Onboarding").tag(OnboardingRecurrence.count)
      } label: {
        Text("When it happens", tableName: "Onboarding")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch model.draft.recurrence {
      case .daily:
        EmptyView()
      case .chosen:
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ShadowFlowLayout {
            ForEach(OnboardingDraft.weekdays, id: \.self) { day in
              ShadowTag(Text(verbatim: QuestsCopy.weekday(day)), isSelected: chosen(day))
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Text("Days of the week", tableName: "Onboarding"))
          if model.problem == .noDays { ShadowValidationMessage(Text(verbatim: OnboardingCopy.problem(.noDays))) }
        }
      case .count:
        OnboardingField(label: Text("How many days a week?", tableName: "Onboarding")) {
          Stepper(value: $model.draft.timesPerWeek, in: OnboardingDraft.timesPerWeek) {
            Text(verbatim: OnboardingCopy.days(model.draft.timesPerWeek)).monospacedDigit()
          }
          Group {
            if days.count == OnboardingDraft.weekdays.count {
              Text("That is every day of the week.", tableName: "Onboarding")
            } else {
              Text("Spread across your week on \(OnboardingCopy.shortWeekdays(days)). Choose the exact days with Chosen days.", tableName: "Onboarding")
            }
          }
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Your week would look like this", tableName: "Onboarding").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        HStack(spacing: Spacing.space2) {
          ForEach(OnboardingDraft.weekdays, id: \.self) { day in
            let on = days.contains(day)
            VStack(spacing: Spacing.space1) {
              Text(verbatim: QuestsCopy.weekday(day)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(on ? ShadowColor.accent : ShadowColor.surfaceWell)
                .frame(height: Spacing.space5)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: QuestsCopy.weekday(day, long: true)))
            .accessibilityAddTraits(on ? .isSelected : [])
          }
        }
        Text(
          "\(OnboardingCopy.daysAWeek(days.count)) · about \(OnboardingCopy.minutes(days.count * OnboardingDraft.questMinutes)) of promises. \(weekNote(days.count))",
          tableName: "Onboarding"
        )
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func weekNote(_ count: Int) -> String {
    count <= OnboardingDraft.lightWeekDays
      ? String(localized: "Light enough to keep on a bad week.", table: "Onboarding")
      : String(localized: "If a bad week makes it hard to keep, drop a day rather than the quest.", table: "Onboarding")
  }

  private func chosen(_ day: LocalDate.Weekday) -> Binding<Bool> {
    Binding(
      get: { model.draft.chosenDays.contains(day) },
      set: { isOn in
        if isOn { model.draft.chosenDays.insert(day) } else { model.draft.chosenDays.remove(day) }
      })
  }
}

struct OnboardingStrictnessStep: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space5) {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        OnboardingLead(
          Text(
            "How much should a missed day cost? This is the one setting that changes how the app feels. You can lower it at any time, and raising it takes effect next week.",
            tableName: "Onboarding"))
        Text("Whatever you choose, a miss never removes experience or a level.", tableName: "Onboarding")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      VStack(spacing: Spacing.space3) {
        ForEach(OnboardingDraft.strictnessOrder, id: \.self) { strictness in
          OnboardingChoice(isSelected: model.draft.strictness == strictness, action: { model.draft.strictness = strictness }) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              HStack(alignment: .firstTextBaseline) {
                Text(verbatim: QuestsCopy.strictness(strictness)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
                Spacer(minLength: Spacing.space2)
                Text(verbatim: OnboardingCopy.cost(strictness)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
              }
              Text(verbatim: QuestsCopy.strictnessRule(strictness)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
          }
        }
      }
      if model.draft.strictness == .anchor { startTime }
      ShadowCallout(
        Text("Shields cover the days you could not help", tableName: "Onboarding"),
        message: Text(
          "You earn one shield for each kept week, up to three. A shield protects a streak on an unavoidable miss, with no explanation required from you.",
          tableName: "Onboarding"),
        intent: .info, systemImage: "shield")
    }
  }

  private var startTime: some View {
    OnboardingField(
      label: Text("Start time", tableName: "Onboarding"),
      helper: Text("Anchor quests happen at a fixed time each day, with thirty minutes of grace.", tableName: "Onboarding"),
      problem: model.startTimeTouched && model.problem == .anchorNeedsTime ? String(localized: "Choose a start time to continue.", table: "Onboarding") : nil
    ) {
      if let minute = model.draft.startMinute {
        DatePicker(
          selection: Binding(get: { QuestCalendar.time(minute) }, set: { model.setStartMinute(QuestCalendar.minute(of: $0)) }), displayedComponents: .hourAndMinute
        ) {
          Text("Start time", tableName: "Onboarding")
        }
        .labelsHidden()
      } else {
        Button {
          model.setStartMinute(OnboardingDraft.standardAnchorStart)
        } label: {
          Text("Choose a start time", tableName: "Onboarding")
        }
        .buttonStyle(.shadowBordered)
      }
    }
  }
}

struct OnboardingReadyStep: View {
  let model: OnboardingModel

  var body: some View {
    let draft = model.draft
    let starts = OnboardingCopy.weekday(model.firstDay?.weekday)
    VStack(alignment: .leading, spacing: Spacing.space4) {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("Your first quest", tableName: "Onboarding").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: draft.trimmedName).shadowFont(.title3).foregroundStyle(ShadowColor.textPrimary)
        ShadowFlowLayout {
          ShadowTag(Text(verbatim: QuestsCopy.stat(draft.stat)))
          ShadowBadge(Text(verbatim: QuestsCopy.strictness(draft.strictness)), intent: .neutral)
          ShadowBadge(Text(verbatim: OnboardingCopy.frequency(draft.scheduledDays.count)), intent: .info)
        }
      }
      VStack(alignment: .leading, spacing: Spacing.space3) {
        row(
          Text("First occurrence", tableName: "Onboarding"),
          model.startsToday
            ? Text("Today · it goes on your Today screen as soon as you start", tableName: "Onboarding")
            : Text("Starts \(starts) · your Today screen stays clear until then", tableName: "Onboarding"))
        row(Text("Reward", tableName: "Onboarding"), Text("Experience when kept · \(QuestsCopy.stat(draft.stat)) up one", tableName: "Onboarding"))
        row(Text("If you miss it", tableName: "Onboarding"), Text(verbatim: QuestsCopy.strictnessRule(draft.strictness)))
        row(
          Text("Home currency", tableName: "Onboarding"),
          Text("\(draft.currency.code) · fixed from here, so your totals stay comparable", tableName: "Onboarding"))
      }
      Group {
        model.startsToday
          ? Text("Next is your Today screen with this quest on it.", tableName: "Onboarding")
          : Text("Next is your Today screen. This quest starts \(starts), so today stays clear until then.", tableName: "Onboarding")
      }
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      Text(
        "Nothing else is set up, and nothing else needs to be — expenses, meals, weight and journal all work whenever you first reach for them.",
        tableName: "Onboarding"
      )
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      if let failure = model.failure {
        ShadowCallout(
          Text("Setup wasn’t saved", tableName: "Onboarding"),
          message: Text(
            verbatim: [failure.headline, String(localized: "Nothing was changed. Go back to check the details, then create it again.", table: "Onboarding")]
              .joined(separator: "\n")),
          intent: .danger
        ) {
          Button {
            Task { await model.finish() }
          } label: {
            Text("Try again", tableName: "Onboarding")
          }
          .disabled(model.isSaving)
        }
      }
    }
  }

  private func row(_ term: Text, _ value: Text) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
        term.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary).frame(width: 150, alignment: .leading)
        value.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: Spacing.space1) {
        term.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        value.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct OnboardingLead: View {
  let text: Text

  init(_ text: Text) {
    self.text = text
  }

  var body: some View {
    text.shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).fixedSize(horizontal: false, vertical: true)
  }
}

/// For a second device: with sync turned on to the same storage, the first device's data arrives and onboarding gives way to it.
struct OnboardingSyncLink: View {
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(SyncRuntimes.self) private var sync
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(
        "Already use Memoir on another device? Turn on sync with the same storage, and Memoir opens with your data instead of setting up again.",
        tableName: "Onboarding"
      )
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      #if os(macOS)
        Button {
          tabs.selected = .sync
          tabs.syncKeys = nil
          openSettings()
        } label: {
          label
        }
        .buttonStyle(.shadowBordered)
      #else
        NavigationLink {
          SyncSettingsView(sync: sync).navigationTitle(Text("Sync", tableName: "Onboarding"))
        } label: {
          label
        }
        .buttonStyle(.shadowBordered)
      #endif
    }
  }

  private var label: some View {
    Label {
      Text("Set Up Sync", tableName: "Onboarding")
    } icon: {
      Image(systemName: "arrow.triangle.2.circlepath")
    }
  }
}

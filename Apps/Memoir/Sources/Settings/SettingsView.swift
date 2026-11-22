import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/settings/settings-screen.tsx`: the displayed title, the day and money, the ways to Sync, AI and Reminders, the owner's data and the app.
struct SettingsView: View {
  let context: MemoirScreenContext
  @State private var model: SettingsModel
  @Environment(AIServices.self) private var ai: AIServices?
  @Environment(\.demoEntry) private var demoEntry

  init(context: MemoirScreenContext) {
    self.context = context
    _model = State(initialValue: SettingsModel(context: context))
  }

  var body: some View {
    List {
      switch model.snapshot.state {
      case .loading:
        Section { ProgressView().frame(maxWidth: .infinity) }
      case .failed(let error):
        Section {
          ShadowCallout(Text("Your settings couldn’t be loaded", tableName: "Settings"), message: error.text, intent: .danger)
        }
      case .loaded(let snapshot):
        SettingsProfileSection(model: model, snapshot: snapshot)
        SettingsDaySection(model: model, snapshot: snapshot)
        SettingsMoneySection(model: model, snapshot: snapshot)
      }
      Section {
        MemoirSettingsLinks(stores: context.stores)
      }
      if ai?.isDemo != true { SettingsDataSection() }
      if demoEntry != nil { SettingsDemoSection() }
      Section {
        NavigationLink(value: MemoirRoute.settings(.about)) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("About Memoir", tableName: "Settings")
            Text("What leaves this device, and the notices of the third-party work Memoir includes.", tableName: "Settings")
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
      } header: {
        Text("About", tableName: "Settings")
      }
    }
    .navigationTitle(Text(MemoirDestination.settings.title))
    .shadowScreen(.root)
    .task { await model.run() }
  }
}

/// The way into the demo while it is not running; the demo itself has no data to export or delete.
private struct SettingsDemoSection: View {
  var body: some View {
    Section {
      Text("See Memoir at work on a sample week, with answers scripted on this device. No key is used, and your own data is not touched.", tableName: "Demo")
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
      TryDemoButton()
    } header: {
      Text("Try the demo", tableName: "Demo")
    }
  }
}

/// "Profile in Memoir" without the platform account the reference shows: Memoir has no account, only the hero's displayed title.
private struct SettingsProfileSection: View {
  let model: SettingsModel
  let snapshot: SettingsSnapshot

  var body: some View {
    Section {
      Picker(selection: Binding(get: { snapshot.displayedTitle }, set: { title in Task { await model.displayTitle(title) } })) {
        ForEach(snapshot.earnedTitles) { title in
          Text(verbatim: HeroCatalogue.name(of: title.id)).tag(Optional(title.id))
        }
        Text("No title", tableName: "Settings").tag(TitleID?.none)
      } label: {
        Text("Displayed title", tableName: "Settings")
      }
      .disabled(snapshot.earnedTitles.isEmpty || model.saving.contains(.title))
      SettingsFailureRow(error: model.failure(for: .title))
    } header: {
      Text("Profile", tableName: "Settings")
    } footer: {
      Text("Titles are earned rather than chosen. This picks which earned one is shown.", tableName: "Settings")
    }
  }
}

private struct SettingsDaySection: View {
  let model: SettingsModel
  let snapshot: SettingsSnapshot

  var body: some View {
    Section {
      if let unknown = model.unknownZone {
        SettingsUnknownZone(identifier: unknown.identifier, offset: unknown.fallbackOffsetMinutes)
      }
      if snapshot.account == .unreadable {
        ShadowCallout(
          Text("Your day and money settings couldn’t be read", tableName: "Settings"),
          message: Text("Another device saved them in a form this version can’t read. Update Memoir to change them here.", tableName: "Settings"),
          intent: .warning)
      }
      schedule
      Picker(selection: Binding(get: { WeekStart(stored: model.account?.weekStart ?? 1) }, set: { start in Task { await model.setWeekStart(start) } })) {
        ForEach(WeekStart.allCases, id: \.self) { start in Text(verbatim: SettingsCopy.weekStart(start)).tag(start) }
      } label: {
        Text("Week starts on", tableName: "Settings")
      }
      .disabled(model.account == nil)
      SettingsFailureRow(error: model.failure(for: .weekStart))
      timeZone
      intensity
    } header: {
      Text("Day and money", tableName: "Settings")
    } footer: {
      Text("Your wake window decides when a day starts and ends for quests, rather than midnight.", tableName: "Settings")
    }
  }

  @ViewBuilder
  private var schedule: some View {
    let shown = model.shownSchedule ?? ScheduleDraft(wake: ScheduleWindow.standard.start, sleep: ScheduleWindow.standard.end)
    DatePicker(
      selection: Binding(get: { QuestCalendar.time(shown.wake) }, set: { date in Task { await model.setWake(QuestCalendar.minute(of: date)) } }),
      displayedComponents: .hourAndMinute
    ) {
      Text("Wake time", tableName: "Settings")
    }
    .disabled(model.account == nil)
    DatePicker(
      selection: Binding(get: { QuestCalendar.time(shown.sleep) }, set: { date in Task { await model.setSleep(QuestCalendar.minute(of: date)) } }),
      displayedComponents: .hourAndMinute
    ) {
      Text("Sleep time", tableName: "Settings")
    }
    .disabled(model.account == nil)
    if let problem = model.scheduleProblem {
      ShadowValidationMessage(Text(verbatim: problem.message))
    }
    SettingsFailureRow(error: model.failure(for: .schedule))
  }

  @ViewBuilder
  private var timeZone: some View {
    NavigationLink(value: MemoirRoute.settings(.timeZone)) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        LabeledContent {
          Text(verbatim: SettingsCopy.zone(snapshot.chosenZone ?? model.deviceZone))
        } label: {
          Text("Time zone", tableName: "Settings")
        }
        zoneHelp.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
    SettingsFailureRow(error: model.failure(for: .timeZone))
  }

  private var zoneHelp: Text {
    if let pending = snapshot.pendingZone, let active = snapshot.zone.inForce {
      return Text(verbatim: SettingsCopy.pending(SettingsCopy.zone(pending), active: SettingsCopy.zone(active)))
    }
    if snapshot.zone.inForce == nil {
      return Text("Not set yet, so your days follow this device’s time zone until you choose one.", tableName: "Settings")
    }
    return Text("Travel does not shift your day unless you change it here.", tableName: "Settings")
  }

  @ViewBuilder
  private var intensity: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Picker(selection: Binding(get: { snapshot.chosenIntensity }, set: { mode in Task { await model.setIntensity(mode) } })) {
        ForEach([IntensityMode.lowIntensity, .standard, .highIntensity], id: \.self) { mode in Text(verbatim: HeroCopy.intensity(mode)).tag(mode) }
      } label: {
        Text("Intensity", tableName: "Settings")
      }
      .disabled(model.saving.contains(.intensity))
      Group {
        if let pending = snapshot.pendingIntensity {
          Text(verbatim: SettingsCopy.pending(HeroCopy.intensity(pending), active: HeroCopy.intensity(snapshot.intensity)))
        } else {
          Text("How much a missed day costs. Lowering it is never punished.", tableName: "Settings")
        }
      }
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
    }
    SettingsFailureRow(error: model.failure(for: .intensity))
  }
}

private struct SettingsMoneySection: View {
  let model: SettingsModel
  let snapshot: SettingsSnapshot
  @FocusState private var budgetFocused: Bool

  var body: some View {
    Section {
      homeCurrency
      if let account = model.account {
        budget(account)
        NavigationLink(value: MemoirRoute.settings(.currencies)) {
          LabeledContent {
            Text(verbatim: account.enabledCurrencies.map(\.code).joined(separator: ", "))
          } label: {
            Text("Currencies", tableName: "Settings")
          }
        }
        SettingsFailureRow(error: model.failure(for: .currencies))
      }
    } header: {
      Text("Money", tableName: "Settings")
    } footer: {
      Text(
        "Fixed when you set up, so the totals in your history stay comparable. Spend in another currency keeps its own and converts to this one.",
        tableName: "Settings")
    }
  }

  @ViewBuilder
  private var homeCurrency: some View {
    switch snapshot.account {
    case .set(let account):
      LabeledContent {
        Text(verbatim: SettingsCurrencies.label(account.defaultCurrency))
      } label: {
        Text("Home currency", tableName: "Settings")
      }
    case .unset:
      Picker(selection: Binding(get: { CurrencyCode?.none }, set: { code in if let code { Task { await model.setHomeCurrency(code) } } })) {
        Text("Choose…", tableName: "Settings").tag(CurrencyCode?.none)
        ForEach(SettingsCurrencies.supported, id: \.self) { code in Text(verbatim: SettingsCurrencies.label(code)).tag(Optional(code)) }
      } label: {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("Home currency", tableName: "Settings")
          Text("Choose it once to set your day and budget. It stays fixed afterwards.", tableName: "Settings")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .disabled(model.saving.contains(.homeCurrency))
      SettingsFailureRow(error: model.failure(for: .homeCurrency))
    case .unreadable:
      EmptyView()
    }
  }

  @ViewBuilder
  private func budget(_ account: AccountSettingsRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Monthly budget", tableName: "Settings")
      HStack(spacing: Spacing.space3) {
        TextField(text: Binding(get: { model.budgetText }, set: { model.editBudget($0) }), prompt: Text(verbatim: "1500")) {
          Text("Monthly budget", tableName: "Settings")
        }
        .labelsHidden()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
        .focused($budgetFocused)
        .onSubmit { Task { await model.commitBudget() } }
        #if os(iOS)
          .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
              Spacer()
              Button {
                budgetFocused = false
              } label: {
                Text("Done", tableName: "Settings")
              }
            }
          }
        #endif
        .disabled(model.saving.contains(.budget))
        Text(verbatim: account.defaultCurrency.code).foregroundStyle(ShadowColor.textSecondary)
        Button {
          Task { await model.clearBudget() }
        } label: {
          Text("Clear", tableName: "Settings")
        }
        .buttonStyle(.borderless)
        .disabled(model.saving.contains(.budget) || (account.monthlyBudget == nil && model.budgetText.isEmpty))
      }
      budgetHelp.shadowFont(.footnote).foregroundStyle(model.budgetProblem ? ShadowColor.dangerText : ShadowColor.textSecondary)
      SettingsFailureRow(error: model.failure(for: .budget))
    }
    .onChange(of: budgetFocused) { _, focused in
      if !focused { Task { await model.commitBudget() } }
    }
  }

  private var budgetHelp: Text {
    if model.budgetProblem { return Text("Enter an amount of zero or more, for example 1500.", tableName: "Settings") }
    #if os(iOS)
      if model.isBudgetDirty { return Text("Unsaved — tap Done or move out of the field to save.", tableName: "Settings") }
    #else
      if model.isBudgetDirty { return Text("Unsaved — press Return or move out of the field to save.", tableName: "Settings") }
    #endif
    return Text("A soft ceiling for the calendar month — nothing here is blocked when you go over it.", tableName: "Settings")
  }
}

private struct SettingsUnknownZone: View {
  let identifier: String
  let offset: Int?

  var body: some View {
    ShadowCallout(
      Text("This device doesn’t know the time zone \(identifier).", tableName: "Settings"),
      message: offset.map {
        Text(
          "Memoir keeps counting the account’s days at \(SettingsCopy.offset(minutes: $0)), the last offset recorded for it, until this device’s time zone data is updated.",
          tableName: "Settings")
      } ?? Text("Memoir counts the account’s days in this device’s time zone until its time zone data is updated.", tableName: "Settings"),
      intent: .neutral, systemImage: "globe")
  }
}

struct SettingsFailureRow: View {
  let error: PresentedError?

  var body: some View {
    if let error { ShadowValidationMessage(error.text) }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      SettingsView(context: context)
    }
    .environment(SyncRuntimes(identity: .memoir, factory: nil))
    .environment(AIServices.memoir())
    .environment(SettingsTabs())
    .shadowTheme()
  }
}

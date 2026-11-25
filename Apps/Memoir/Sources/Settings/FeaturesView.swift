import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Settings › Features: one switch per module with what it covers; turning one off hides it and deletes nothing.
struct FeaturesView: View {
  @State private var model: FeaturesModel

  init(context: MemoirScreenContext, effects: MemoirModuleEffects?) {
    _model = State(initialValue: FeaturesModel(context: context, effects: effects))
  }

  var body: some View {
    List {
      switch model.standing.state {
      case .loading:
        Section { ProgressView().frame(maxWidth: .infinity) }
      case .failed(let error):
        Section {
          ShadowCallout(Text("Your features couldn’t be loaded", tableName: "Settings"), message: error.text, intent: .danger)
        }
      case .loaded(.unset):
        FeaturesHomeCurrencySection(model: model)
      case .loaded(.unreadable):
        Section {
          ShadowCallout(
            Text("Your features couldn’t be read", tableName: "Settings"),
            message: Text("Another device saved your settings in a form this version can’t read. Update Memoir to change them here.", tableName: "Settings"),
            intent: .warning)
        }
      case .loaded(.set):
        FeaturesToggles(model: model)
      }
    }
    .navigationTitle(Text("Features", tableName: "Settings"))
    .shadowScreen(.pushed)
    .task { await model.run() }
    .confirmationDialog(
      Text(verbatim: model.confirmation.map { FeaturesView.pauseTitle($0.pausing) } ?? ""),
      isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } }), titleVisibility: .visible,
      presenting: model.confirmation
    ) { _ in
      Button(role: .destructive) {
        Task { await model.confirm() }
      } label: {
        Text("Pause and Turn Off", tableName: "Settings")
      }
      Button(role: .cancel) {
        model.cancelConfirmation()
      } label: {
        Text("Cancel", tableName: "Settings")
      }
    } message: { _ in
      Text(
        "Turning Quests off pauses every active quest, and turning it back on doesn’t restart them. If today’s plan is locked, its reward for today is lost.",
        tableName: "Settings")
    }
  }

  static func pauseTitle(_ count: Int) -> String {
    String(localized: "Pause \(count) quests?", table: "Settings")
  }
}

private struct FeaturesToggles: View {
  let model: FeaturesModel

  var body: some View {
    Section {
      ForEach(SettingsCopy.moduleOrder, id: \.self) { module in
        Toggle(isOn: Binding(get: { model.isOn(module) }, set: { isOn in Task { await model.set(module, enabled: isOn) } })) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: SettingsCopy.module(module))
            Text(verbatim: SettingsCopy.moduleDescription(module))
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
        .disabled(!model.canChange)
      }
      SettingsFailureRow(error: model.failure)
    } footer: {
      Text(
        "Turning a feature off only hides it: nothing is deleted, and its data keeps syncing and stays in your exports. Turning Body off stops reading Apple Health and keeps Activity off iCloud.",
        tableName: "Settings")
    }
  }
}

/// D20: a vault without settings, as one with data from before onboarding existed, sets its home currency before its features.
private struct FeaturesHomeCurrencySection: View {
  let model: FeaturesModel

  var body: some View {
    Section {
      ShadowCallout(
        Text("Choose your home currency first", tableName: "Settings"),
        message: Text("Features are chosen once Memoir knows your home currency. It’s set once and stays fixed.", tableName: "Settings"),
        intent: .neutral, systemImage: "dollarsign.circle")
      HomeCurrencyPicker(isSaving: model.isSaving) { code in Task { await model.setHomeCurrency(code) } }
      SettingsFailureRow(error: model.failure)
    }
  }
}

#Preview("Every feature") {
  @Previewable @State var context: MemoirScreenContext?
  NavigationStack {
    if let context { FeaturesView(context: context, effects: nil) } else { ProgressView() }
  }
  .shadowTheme()
  .task {
    guard context == nil, let preview = try? MemoirScreenContext.inMemory(), let euro = CurrencyCode("EUR") else { return }
    try? await SettingsModel.createSettings(euro, through: preview.writer)
    context = preview
  }
}

#Preview("No home currency") {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      FeaturesView(context: context, effects: nil)
    }
    .shadowTheme()
  }
}

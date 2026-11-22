import ShadowAI
import ShadowDesignSystem
import ShadowStore
import SwiftUI

public struct AISettingsView: View {
  @State private var model: AISettingsModel
  @State private var removing: ModelProviderKind?

  public init(services: AIServices, store: VaultStore?) {
    _model = State(initialValue: AISettingsModel(services: services, store: store))
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if model.provider == .demo {
          demoSection
        } else {
          providerSection
          KeySection(model: model, provider: .anthropic, removing: $removing)
          KeySection(model: model, provider: .openRouter, removing: $removing)
          if model.provider == .openRouter || model.storedKeys.contains(.openRouter) { ModelsSection(model: model) }
          if model.showsUnrestrictedModel { UnrestrictedModelSection(model: model) }
          CapsSection(model: model)
        }
        ConsentSection(model: model)
        if model.provider != .demo { TryDemoSection(identity: model.services.identity) }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .task { await model.load() }
    .confirmationDialog(
      Text("Remove this key?", tableName: "AISettings", bundle: .module), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible,
      presenting: removing
    ) { provider in
      Button(role: .destructive) {
        Task { await model.removeKey(provider) }
      } label: {
        Text("Remove Key", tableName: "AISettings", bundle: .module)
      }
    } message: { provider in
      Text("\(provider.displayName) stops working on every device that shares your keychain until you add a key again.", tableName: "AISettings", bundle: .module)
    }
    .alert(
      Text("Something went wrong", tableName: "AISettings", bundle: .module), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
      presenting: model.failure
    ) { _ in
      Button {
        model.failure = nil
      } label: {
        Text("OK", tableName: "AISettings", bundle: .module)
      }
    } message: { failure in
      failure.text
    }
  }

  private var demoSection: some View {
    ShadowGroupedSection {
      ShadowCallout(
        Text("This is the demo. Its answers come from a script on this device; no key is used and nothing is sent.", tableName: "AISettings", bundle: .module),
        intent: .info, systemImage: "play.circle"
      ) { EmptyView() }
      .padding(Spacing.space3)
    } header: {
      Text("AI provider", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    }
  }

  private var providerSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Picker(selection: Binding(get: { model.provider }, set: { model.select($0) })) {
          ForEach(ModelProviderKind.keyed, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
        } label: {
          Text("Provider", tableName: "AISettings", bundle: .module)
        }
        .pickerStyle(.segmented)
        if !model.storedKeys.contains(model.provider) {
          ShadowCallout(
            Text("Add your \(model.provider.displayName) key below to use it.", tableName: "AISettings", bundle: .module), intent: .warning, systemImage: "key"
          ) { EmptyView() }
        }
        if !model.missingModelPaces.isEmpty {
          ShadowCallout(Text("Choose a model for each pace below.", tableName: "AISettings", bundle: .module), intent: .warning, systemImage: "slider.horizontal.3") { EmptyView() }
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("AI provider", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Standard requests go to this provider. Keys sync through your keychain; the provider choice, models and spend caps stay on this device.", tableName: "AISettings",
        bundle: .module)
    }
  }
}

private struct KeySection: View {
  let model: AISettingsModel
  let provider: ModelProviderKind
  @Binding var removing: ModelProviderKind?

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if model.storedKeys.contains(provider) {
          HStack {
            Label {
              Text("Key saved", tableName: "AISettings", bundle: .module)
            } icon: {
              Image(systemName: "checkmark.seal")
            }
            Spacer(minLength: Spacing.space3)
            Button(role: .destructive) {
              removing = provider
            } label: {
              Text("Remove Key", tableName: "AISettings", bundle: .module)
            }
          }
        }
        if provider == .openRouter { OpenRouterSignInButton(model: model) }
        KeyEntryForm(model: model, provider: provider)
      }
      .padding(Spacing.space3)
    } header: {
      Text(verbatim: provider.displayName).shadowFont(.headline)
    }
  }
}

struct ModelsSection: View {
  let model: AISettingsModel

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ForEach(Pace.allCases, id: \.self) { pace in paceRow(pace) }
        if let failure = model.modelsFailure { ShadowValidationMessage(failure.text) }
        HStack {
          if model.isLoadingModels { ProgressView().controlSize(.small) }
          Spacer(minLength: Spacing.space3)
          Button {
            model.saveModels()
          } label: {
            Text("Save Models", tableName: "AISettings", bundle: .module)
          }
          .disabled(!model.canSaveModels)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("OpenRouter models", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Type the OpenRouter model identifier for each pace, for example vendor/model-name. Leave a pace empty to leave it unavailable. Authoring screens show only the pace, never the model.",
        tableName: "AISettings", bundle: .module)
    }
  }

  private func paceRow(_ pace: Pace) -> some View {
    @Bindable var model = model
    return VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: pace.displayName).shadowFont(.subheadline)
      HStack(spacing: Spacing.space2) {
        TextField(
          text: Binding(get: { model.modelDrafts[pace] ?? "" }, set: { model.modelDrafts[pace] = $0 }), prompt: Text("Model identifier", tableName: "AISettings", bundle: .module)
        ) {
          Text(verbatim: pace.displayName)
        }
        .shadowField()
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        if !model.listedModels.isEmpty {
          Menu {
            ForEach(model.listedModels, id: \.id) { listed in
              Button {
                model.choose(listed, for: pace)
              } label: {
                Text(verbatim: listed.name ?? listed.id)
              }
            }
          } label: {
            Text("Choose", tableName: "AISettings", bundle: .module)
          }
          .menuStyle(.button)
          .fixedSize()
        }
      }
      if model.modelIssue(pace) != nil {
        ShadowValidationMessage(Text("A model identifier has no spaces.", tableName: "AISettings", bundle: .module))
      } else if let draft = model.modelDrafts[pace], !draft.isEmpty, !model.listedModels.isEmpty,
        !model.listedModels.contains(where: { $0.id == draft.trimmingCharacters(in: .whitespaces) })
      {
        Text("OpenRouter's list does not include this identifier.", tableName: "AISettings", bundle: .module).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

private struct CapsSection: View {
  let model: AISettingsModel

  var body: some View {
    @Bindable var model = model
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        capField(Text("Daily cap (USD)", tableName: "AISettings", bundle: .module), text: $model.dailyText, issue: model.dailyIssue)
        capField(Text("Monthly cap (USD)", tableName: "AISettings", bundle: .module), text: $model.monthlyText, issue: model.monthlyIssue)
        HStack {
          Spacer(minLength: Spacing.space3)
          Button {
            model.saveCaps()
          } label: {
            Text("Save Caps", tableName: "AISettings", bundle: .module)
          }
          .disabled(!model.canSaveCaps)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Spend caps", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Requests are refused once your recorded spend reaches a cap. Leave a field empty for no cap. Caps apply to this device's view of the ledger.", tableName: "AISettings",
        bundle: .module)
    }
  }

  private func capField(_ title: Text, text: Binding<String>, issue: SpendCapIssue?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      title.shadowFont(.subheadline)
      TextField(text: text, prompt: Text("No cap", tableName: "AISettings", bundle: .module)) { title }
        .shadowField()
        .autocorrectionDisabled()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
      if let issue { ShadowValidationMessage(Self.message(for: issue)) }
    }
  }

  private static func message(for issue: SpendCapIssue) -> Text {
    switch issue {
    case .invalid: Text("Enter an amount in dollars, such as 5 or 2.50.", tableName: "AISettings", bundle: .module)
    case .notPositive: Text("A cap must be more than zero. Clear the field for no cap.", tableName: "AISettings", bundle: .module)
    case .tooLarge: Text("A cap can be at most 1,000,000 dollars.", tableName: "AISettings", bundle: .module)
    case .dailyAboveMonthly: Text("The daily cap cannot be higher than the monthly cap.", tableName: "AISettings", bundle: .module)
    }
  }
}

private struct ConsentSection: View {
  let model: AISettingsModel

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if model.consentsUnavailable {
          Text("Allowed sharing is unavailable right now.", tableName: "AISettings", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
        } else if model.consents.isEmpty {
          Text("Nothing has been allowed yet. \(model.services.identity.displayName) asks the first time it needs to send something.", tableName: "AISettings", bundle: .module)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        ForEach(model.consents) { consent in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.space05) {
              Text(verbatim: consent.disclosure.title)
              Group {
                if consent.provider == .demo {
                  Text("Demo · on this device", tableName: "AISettings", bundle: .module)
                } else {
                  Text(verbatim: "\(consent.provider.displayName) · \(consent.host)")
                }
              }
              .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
            Spacer(minLength: Spacing.space3)
            Button(role: .destructive) {
              Task { await model.revoke(consent) }
            } label: {
              Text("Revoke", tableName: "AISettings", bundle: .module)
            }
          }
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Allowed sharing", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text("Revoking stops \(model.services.identity.displayName) sending that data to the provider until you allow it again.", tableName: "AISettings", bundle: .module)
    }
  }
}

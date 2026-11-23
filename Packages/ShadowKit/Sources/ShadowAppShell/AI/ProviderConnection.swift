import Observation
import ShadowAI
import ShadowDesignSystem
import SwiftUI

/// Connecting a provider at the first AI action that has none: Anthropic by a pasted key (recommended), OpenRouter by sign-in or a pasted key and then a
/// model for each pace. A key saved here for the chosen provider, or a saved one the owner picks, also makes it the provider standard requests go to.
@MainActor
@Observable
final class ProviderConnectionModel {
  static let recommended = ModelProviderKind.anthropic

  let settings: AISettingsModel
  var choice = ProviderConnectionModel.recommended
  private(set) var isConnected = false

  /// A provider already usable but missing a pace's model opens on that provider, asking only for the models.
  init(services: AIServices) {
    settings = AISettingsModel(services: services, store: nil)
    if services.hasUsableProvider {
      choice = services.settings.provider
      isConnected = true
    }
    settings.keySaved = { [weak self] provider in self?.saved(provider) }
  }

  var hasStoredChoice: Bool { settings.storedKeys.contains(choice) }

  var needsModels: Bool { choice == .openRouter && Pace.allCases.contains { settings.assignedModels[$0]?.isEmpty != false } }

  var isFinished: Bool { isConnected && settings.services.assignsEveryPace }

  func load() async {
    await settings.load()
  }

  func useSavedKey() {
    guard hasStoredChoice else { return }
    connect(choice)
  }

  private func saved(_ provider: ModelProviderKind) {
    guard provider == choice else { return }
    connect(provider)
  }

  private func connect(_ provider: ModelProviderKind) {
    settings.select(provider)
    isConnected = settings.services.hasUsableProvider
  }
}

struct ProviderConnectionSheet: View {
  @State private var model: ProviderConnectionModel
  @Environment(\.dismiss) private var dismiss

  init(services: AIServices) {
    _model = State(initialValue: ProviderConnectionModel(services: services))
  }

  var body: some View {
    @Bindable var model = model
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text(
          "\(model.settings.services.identity.displayName) writes with a model from a provider you choose, under your own account. Nothing is sent until you allow it.",
          tableName: "AISettings", bundle: .module)
        Picker(selection: $model.choice) {
          ForEach(ModelProviderKind.keyed, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
        } label: {
          Text("Provider", tableName: "AISettings", bundle: .module)
        }
        .pickerStyle(.segmented)
        .disabled(model.isConnected)
        if model.choice == ProviderConnectionModel.recommended && !model.isConnected {
          Text("Recommended: paste an Anthropic API key. It is checked at no cost before it is saved.", tableName: "AISettings", bundle: .module)
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        if model.isConnected && !model.isFinished {
          ShadowCallout(
            Text("Choose a model for each pace to finish connecting OpenRouter.", tableName: "AISettings", bundle: .module), intent: .info,
            systemImage: "slider.horizontal.3"
          ) { EmptyView() }
          ModelsSection(model: model.settings)
        } else if model.hasStoredChoice {
          Button {
            model.useSavedKey()
          } label: {
            Text("Use Your Saved \(model.choice.displayName) Key", tableName: "AISettings", bundle: .module)
          }
          .buttonStyle(.borderedProminent)
        } else {
          if model.choice == .openRouter { OpenRouterSignInButton(model: model.settings) }
          KeyEntryForm(model: model.settings, provider: model.choice)
        }
        if model.needsModels && !model.isConnected {
          ShadowCallout(
            Text("OpenRouter also needs a model for each pace, chosen here once it is connected.", tableName: "AISettings", bundle: .module), intent: .info,
            systemImage: "slider.horizontal.3"
          ) { EmptyView() }
        }
      }
      .padding(.bottom, Spacing.space1)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text("Connect an AI Provider", tableName: "AISettings", bundle: .module),
      cancel: ShadowSheetCancel(Text("Not Now", tableName: "AISettings", bundle: .module)) { dismiss() }
    )
    .shadowSheetStyle(.form)
    .environment(\.appIdentity, model.settings.services.identity)
    .task { await model.load() }
    .onChange(of: model.isFinished) {
      if model.isFinished { dismiss() }
    }
  }
}

extension View {
  /// Asks for a provider before an AI action that has none; `onConnected` runs once the sheet is gone and only if a provider is connected with a model for
  /// every pace, so a consent sheet the action then needs is presented after it.
  public func aiProviderSheet(isPresented: Binding<Bool>, services: AIServices, onConnected: @escaping () -> Void) -> some View {
    sheet(
      isPresented: isPresented, onDismiss: { if services.isReadyForStandardCalls { onConnected() } },
      content: { ProviderConnectionSheet(services: services) })
  }
}

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
  /// The owner chose the demo instead: the sheet closes and the action that opened it does not go on.
  private(set) var leftForDemo = false

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

  var closes: Bool { isFinished || leftForDemo }

  /// Whether the action held for a provider goes on once the sheet is gone.
  static func continuesHeldAction(services: AIServices, leftForDemo: Bool) -> Bool {
    !leftForDemo && services.isReadyForStandardCalls
  }

  func tryDemo(_ entry: DemoEntry) {
    guard !entry.isEntering else { return }
    leftForDemo = true
    entry.enter()
  }

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
  let leftForDemo: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.demoEntry) private var demoEntry

  init(services: AIServices, leftForDemo: @escaping () -> Void) {
    _model = State(initialValue: ProviderConnectionModel(services: services))
    self.leftForDemo = leftForDemo
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
        if let demoEntry, !model.isConnected { demoOffer(demoEntry) }
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
    .onChange(of: model.closes) {
      guard model.closes else { return }
      if model.leftForDemo { leftForDemo() }
      dismiss()
    }
  }

  private func demoOffer(_ entry: DemoEntry) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Try without a key", tableName: "Demo", bundle: .module).shadowFont(.headline)
      Text(
        "See \(model.settings.services.identity.displayName) at work on sample content, with answers scripted on this device. No key is used, and your own data and keys are not touched.",
        tableName: "Demo", bundle: .module
      )
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      Button {
        model.tryDemo(entry)
      } label: {
        Label {
          Text("Try the Demo", tableName: "Demo", bundle: .module)
        } icon: {
          Image(systemName: "play.circle")
        }
      }
      .disabled(entry.isEntering)
    }
    .padding(.top, Spacing.space2)
  }
}

extension View {
  /// Asks for a provider before an AI action that has none; `onConnected` runs once the sheet is gone and only if a provider is connected with a model for
  /// every pace, so a consent sheet the action then needs is presented after it.
  /// Choosing the demo there instead closes it without the action.
  public func aiProviderSheet(isPresented: Binding<Bool>, services: AIServices, onConnected: @escaping () -> Void) -> some View {
    modifier(ProviderSheet(isPresented: isPresented, services: services, onConnected: onConnected))
  }
}

private struct ProviderSheet: ViewModifier {
  @Binding var isPresented: Bool
  let services: AIServices
  let onConnected: () -> Void
  @State private var leftForDemo = false

  func body(content: Content) -> some View {
    content.sheet(
      isPresented: $isPresented,
      onDismiss: {
        let continues = ProviderConnectionModel.continuesHeldAction(services: services, leftForDemo: leftForDemo)
        leftForDemo = false
        if continues { onConnected() }
      },
      content: { ProviderConnectionSheet(services: services) { leftForDemo = true } })
  }
}

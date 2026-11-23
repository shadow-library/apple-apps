import ShadowAI
import ShadowDesignSystem
import SwiftUI

struct KeyEntryForm: View {
  let model: AISettingsModel
  let provider: ModelProviderKind

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      SecureField(text: draft, prompt: keyPrompt) {
        Text("API key", tableName: "AISettings", bundle: .module)
      }
      .shadowField()
      .textContentType(.password)
      .autocorrectionDisabled()
      .disabled(model.entry(provider) == .checking)
      .onSubmit { Task { await model.submitKey(for: provider) } }
      feedback
      HStack {
        if model.entry(provider) == .checking { ProgressView().controlSize(.small) }
        Spacer(minLength: Spacing.space3)
        Button {
          Task { await model.submitKey(for: provider) }
        } label: {
          Text("Check and Save", tableName: "AISettings", bundle: .module)
        }
        .disabled(!model.canSubmitKey(provider))
      }
    }
  }

  private var keyPrompt: Text {
    model.storedKeys.contains(provider)
      ? Text("Paste a new key to replace it", tableName: "AISettings", bundle: .module) : Text("Paste your key", tableName: "AISettings", bundle: .module)
  }

  private var draft: Binding<String> {
    Binding(
      get: { model.keyDrafts[provider] ?? "" },
      set: {
        model.keyDrafts[provider] = $0
        model.keyDraftChanged(provider)
      })
  }

  @ViewBuilder
  private var feedback: some View {
    switch model.entry(provider) {
    case .idle, .checking: EmptyView()
    case .rejected(let error), .failed(let error): ShadowValidationMessage(error.text)
    case .unverified(let error):
      ShadowCallout(
        Text("The key could not be checked.", tableName: "AISettings", bundle: .module), message: error.text, intent: .warning, systemImage: "exclamationmark.triangle"
      ) {
        Button {
          Task { await model.saveUnverified(for: provider) }
        } label: {
          Text("Save Anyway", tableName: "AISettings", bundle: .module)
        }
      }
    }
  }
}

import ShadowDesignSystem
import SwiftUI

struct UnrestrictedModelSection: View {
  let model: AISettingsModel

  var body: some View {
    @Bindable var model = model
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        TextField(text: $model.unrestrictedDraft, prompt: Text("Model identifier", tableName: "AISettings", bundle: .module)) {
          Text("Unrestricted writing model", tableName: "AISettings", bundle: .module)
        }
        .shadowField()
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        if model.unrestrictedIssue != nil {
          ShadowValidationMessage(Text("A model identifier has no spaces.", tableName: "AISettings", bundle: .module))
        }
        HStack {
          Spacer(minLength: Spacing.space3)
          Button {
            model.saveUnrestricted()
          } label: {
            Text("Save Model", tableName: "AISettings", bundle: .module)
          }
          .disabled(!model.canSaveUnrestricted)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Unrestricted writing model", tableName: "AISettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Unrestricted writing always goes to OpenRouter with your OpenRouter key, to the model typed here. Leave it empty to leave unrestricted writing unavailable.",
        tableName: "AISettings", bundle: .module)
    }
  }
}

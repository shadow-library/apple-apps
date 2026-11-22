import ShadowDesignSystem
import ShadowSync
import SwiftUI

struct PhraseRecoveryView: View {
  @Environment(\.appIdentity) private var app
  let model: PhraseRecoveryModel
  let close: () -> Void

  var body: some View {
    @Bindable var model = model
    KeyFlowSection(title: Text("Enter Recovery Phrase", tableName: "SyncKeys", bundle: .module), failure: model.failure) {
      if case .finished(let added) = model.step {
        ShadowCallout(
          Text("Your \(app.vaultNoun)'s key is on this device.", tableName: "SyncKeys", bundle: .module),
          message: added > 1 ? Text("\(added) keys were added.", tableName: "SyncKeys", bundle: .module) : nil, intent: .success, systemImage: "key"
        ) { EmptyView() }
      } else {
        Text("Type or paste the 24 words of your recovery phrase, in order. Capitals and extra spaces do not matter.", tableName: "SyncKeys", bundle: .module)
          .foregroundStyle(ShadowColor.textSecondary)
        ShadowTextEditor(text: edited($model.text), placeholder: Text("Recovery phrase", tableName: "SyncKeys", bundle: .module), minHeight: 96) { _ in
          Text("\(wordCount) of 24 words", tableName: "SyncKeys", bundle: .module)
        }
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .privacySensitive()
        .disabled(model.step == .recovering)
        .concealedWhileInactive()
        if model.step == .recovering { KeyFlowProgress(text: Text("Looking for your \(app.vaultNoun)'s keys…", tableName: "SyncKeys", bundle: .module)) }
      }
    } footer: {
      Spacer(minLength: Spacing.space3)
      if case .finished = model.step {
        Button(action: close) {
          Text("Done", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
      } else {
        Button(action: close) {
          Text("Cancel", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowBordered)
        .disabled(model.step == .recovering)
        Button {
          Task { await model.recover() }
        } label: {
          Text("Recover Key", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
        .disabled(!model.canRecover)
      }
    }
  }

  private var wordCount: Int {
    model.text.split(whereSeparator: \.isWhitespace).count
  }

  private func edited(_ text: Binding<String>) -> Binding<String> {
    Binding(
      get: { text.wrappedValue },
      set: {
        text.wrappedValue = $0
        model.edited()
      })
  }
}

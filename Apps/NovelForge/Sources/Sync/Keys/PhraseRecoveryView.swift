import ShadowDesignSystem
import ShadowSync
import SwiftUI

struct PhraseRecoveryView: View {
  let model: PhraseRecoveryModel
  let close: () -> Void

  var body: some View {
    @Bindable var model = model
    KeyFlowSection(title: Text("Enter Recovery Phrase", tableName: "SyncKeys"), failure: model.failure) {
      if case .finished(let added) = model.step {
        ShadowCallout(
          Text("Your library's key is on this device.", tableName: "SyncKeys"),
          message: added > 1 ? Text("\(added) keys were added.", tableName: "SyncKeys") : nil, intent: .success, systemImage: "key"
        ) { EmptyView() }
      } else {
        Text("Type or paste the 24 words of your recovery phrase, in order. Capitals and extra spaces do not matter.", tableName: "SyncKeys")
          .foregroundStyle(ShadowColor.textSecondary)
        ShadowTextEditor(text: edited($model.text), placeholder: Text("Recovery phrase", tableName: "SyncKeys"), minHeight: 96) { _ in
          Text("\(wordCount) of 24 words", tableName: "SyncKeys")
        }
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .privacySensitive()
        .disabled(model.step == .recovering)
        .concealedWhileInactive()
        if model.step == .recovering { KeyFlowProgress(text: Text("Looking for your library's keys…", tableName: "SyncKeys")) }
      }
    } footer: {
      Spacer(minLength: Spacing.space3)
      if case .finished = model.step {
        Button(action: close) {
          Text("Done", tableName: "SyncKeys")
        }
        .buttonStyle(.shadowFilled)
      } else {
        Button(action: close) {
          Text("Cancel", tableName: "SyncKeys")
        }
        .buttonStyle(.shadowBordered)
        .disabled(model.step == .recovering)
        Button {
          Task { await model.recover() }
        } label: {
          Text("Recover Key", tableName: "SyncKeys")
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

import ShadowDesignSystem
import SwiftUI

struct RecoveryPhraseSetupView: View {
  @Environment(\.appIdentity) private var app
  let model: RecoveryPhraseSetupModel
  let close: () -> Void

  var body: some View {
    KeyFlowSection(title: Text("Recovery Phrase", tableName: "SyncKeys", bundle: .module), failure: model.failure) {
      switch model.step {
      case .showing: PhraseWords(words: model.words)
      case .confirming: PhraseConfirmation(model: model)
      case .saving: KeyFlowProgress(text: Text("Saving your recovery phrase…", tableName: "SyncKeys", bundle: .module))
      case .finished(let isComplete): finished(isComplete: isComplete)
      }
    } footer: {
      footer
    }
  }

  private func finished(isComplete: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowCallout(
        Text("Your recovery phrase is set up.", tableName: "SyncKeys", bundle: .module),
        message: Text(
          "With it, any device can open your \(app.vaultNoun)'s keys, even when none of your devices is at hand. Keep it somewhere safe.", tableName: "SyncKeys", bundle: .module),
        intent: .success, systemImage: "checkmark.shield"
      ) { EmptyView() }
      if !isComplete {
        Text("A few of its copies finish the next time this device syncs.", tableName: "SyncKeys", bundle: .module)
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  @ViewBuilder
  private var footer: some View {
    switch model.step {
    case .showing:
      cancel
      Spacer(minLength: Spacing.space3)
      Button(action: model.wroteDown) {
        Text("I Wrote Them Down", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
    case .confirming, .saving:
      Button(action: model.showWordsAgain) {
        Text("Show the Words Again", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowBordered)
      .disabled(model.step == .saving)
      Spacer(minLength: Spacing.space3)
      cancel.disabled(model.step == .saving)
      Button {
        Task { await model.confirm() }
      } label: {
        Text("Save Phrase", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
      .disabled(!model.canConfirm)
    case .finished:
      Spacer(minLength: Spacing.space3)
      Button(action: close) {
        Text("Done", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
    }
  }

  private var cancel: some View {
    Button(action: close) {
      Text("Cancel", tableName: "SyncKeys", bundle: .module)
    }
    .buttonStyle(.shadowBordered)
  }
}

private struct PhraseWords: View {
  @Environment(\.appIdentity) private var app
  let words: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text(
        "Write these 24 words down in order and keep them somewhere safe, away from your devices. They are shown only now, and \(app.displayName) does not keep them. Anyone who has them can open your \(app.vaultNoun).",
        tableName: "SyncKeys", bundle: .module
      )
      .foregroundStyle(ShadowColor.textSecondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Spacing.space2, alignment: .leading)], alignment: .leading, spacing: Spacing.space2) {
        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(verbatim: "\(index + 1)").monospacedDigit().foregroundStyle(ShadowColor.textTertiary).frame(minWidth: 22, alignment: .trailing)
            Text(verbatim: word).monospaced().foregroundStyle(ShadowColor.textPrimary)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(Spacing.space3)
      .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .textSelection(.disabled)
      .concealedWhileInactive()
    }
  }
}

private struct PhraseConfirmation: View {
  let model: RecoveryPhraseSetupModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Type these words from what you wrote down, to check it.", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
      ForEach(model.positions, id: \.self) { position in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("Word \(position)", tableName: "SyncKeys", bundle: .module).shadowFont(.subheadline)
          TextField(text: entry(position)) { Text("Word \(position)", tableName: "SyncKeys", bundle: .module) }
            .shadowField()
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
            .privacySensitive()
            .onSubmit { Task { await model.confirm() } }
          if model.mismatched.contains(position) {
            ShadowValidationMessage(Text("This is not word \(position).", tableName: "SyncKeys", bundle: .module))
          }
        }
      }
    }
    .disabled(model.step == .saving)
    .concealedWhileInactive()
  }

  private func entry(_ position: Int) -> Binding<String> {
    Binding(get: { model.entries[position] ?? "" }, set: { model.entries[position] = $0 })
  }
}

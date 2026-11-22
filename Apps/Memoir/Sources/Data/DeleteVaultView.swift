import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// "Delete your data" (`features/settings/delete-screen.tsx`): what would be erased and what stays, two statements, the typed word, then the last
/// question.
struct DeleteVaultView: View {
  @Environment(MemoirVaultDeletion.self) private var deletion: MemoirVaultDeletion?
  @State private var model: DeleteVaultModel
  @FocusState private var typing: Bool

  init(context: MemoirScreenContext) {
    _model = State(initialValue: DeleteVaultModel(context: context))
  }

  var body: some View {
    List {
      Section {
        Text("This erases everything Memoir keeps on this device and turns sync off.", tableName: "Data").shadowFont(.subheadline)
        if model.stopped {
          ShadowCallout(Text("Stopped. Nothing was started and nothing was erased.", tableName: "Data"), intent: .neutral)
        }
        if let failure = model.failure {
          ShadowCallout(Text("The deletion did not start", tableName: "Data"), message: failure.text, intent: .danger)
        }
      }
      switch model.stage {
      case .acknowledging: acknowledging
      case .confirming: confirming
      case .deleting:
        Section {
          HStack(spacing: Spacing.space3) {
            ProgressView()
            Text("Deleting…", tableName: "Data")
          }
        }
      }
      if model.stage == .acknowledging {
        VaultContentsSections(load: model.contents)
      }
      DeleteVaultStays()
      if model.stage == .acknowledging { lighterOptions }
    }
    .navigationTitle(Text("Delete your data", tableName: "Data"))
    .shadowScreen(.pushed)
    .task { await model.load() }
    .confirmationDialog(Text("Delete all your data now?", tableName: "Data"), isPresented: $model.isAskingToDelete, titleVisibility: .visible) {
      Button(role: .destructive) {
        guard let deletion else { return }
        Task { await model.delete { () throws(VaultDeletionError) in try await deletion.delete() } }
      } label: {
        Text("Delete everything", tableName: "Data")
      }
      .shadowDestructiveDialogAction()
      Button(role: .cancel) {
        model.isAskingToDelete = false
      } label: {
        Text("Keep my data", tableName: "Data")
      }
      .shadowDialogCancelAction()
    } message: {
      Text(
        "This erases your quests and history, your money, your journal, your body and health records and your coaching results from this device, and turns sync off. It starts the moment you confirm, and it cannot be stopped or undone.",
        tableName: "Data")
    }
    .confirmationDialog(Text("Stop deleting your data?", tableName: "Data"), isPresented: $model.isAskingToStop, titleVisibility: .visible) {
      Button {
        model.stop()
      } label: {
        Text("Stop here", tableName: "Data")
      }
      Button(role: .cancel) {
        model.isAskingToStop = false
      } label: {
        Text("Keep going", tableName: "Data")
      }
      .shadowDialogCancelAction()
    } message: {
      Text(
        "Nothing has started and nothing is erased. The two statements you ticked are cleared, so starting again begins from the top.", tableName: "Data")
    }
  }

  @ViewBuilder
  private var acknowledging: some View {
    Section {
      Text(verbatim: DataCopy.terms)
      ForEach(DeleteVaultModel.Acknowledgement.allCases, id: \.self) { acknowledgement in
        Toggle(
          isOn: Binding(get: { model.acknowledged.contains(acknowledgement) }, set: { model.setAcknowledged(acknowledgement, $0) })
        ) {
          Text(verbatim: DataCopy.acknowledgement(acknowledgement))
        }
      }
      Button(role: .destructive) {
        model.continueToConfirmation()
      } label: {
        Text("Continue to confirmation", tableName: "Data")
      }
      .disabled(!model.canContinue)
      NavigationLink(value: MemoirRoute.settings(.export)) {
        Text("Export first", tableName: "Data")
      }
    } header: {
      Text("How it works", tableName: "Data")
    } footer: {
      if !model.canContinue {
        Text("Both statements need to be true before anything goes further.", tableName: "Data")
      }
    }
  }

  @ViewBuilder
  private var confirming: some View {
    Section {
      Text("What is left is your own confirmation.", tableName: "Data")
      Text(verbatim: DataCopy.terms).foregroundStyle(ShadowColor.textSecondary)
      TextField(text: $model.typed, prompt: Text("Type \(DataCopy.typedConfirmation) to confirm", tableName: "Data")) {
        Text("Type \(DataCopy.typedConfirmation) to confirm", tableName: "Data")
      }
      .focused($typing)
      .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.characters)
      #endif
      .onSubmit { model.askToDelete() }
      Button(role: .destructive) {
        typing = false
        model.askToDelete()
      } label: {
        Text("Delete everything…", tableName: "Data")
      }
      .disabled(!model.canDelete || deletion == nil)
      Button {
        model.askToStop()
      } label: {
        Text("Stop here", tableName: "Data")
      }
    } header: {
      Text("Confirm the deletion", tableName: "Data")
    }
  }

  private var lighterOptions: some View {
    Section {
      DeleteVaultOption(
        title: Text("Pause instead", tableName: "Data"),
        message: Text("Set intensity to gentle, or deactivate your quests. Nothing is deleted and the streaks stay as records.", tableName: "Data"))
      DeleteVaultOption(
        title: Text("Export and keep your data", tableName: "Data"),
        message: Text("Take the archive now. Your data can be deleted at any later time.", tableName: "Data"))
      DeleteVaultOption(
        title: Text("Turn off coaching and reminders", tableName: "Data"),
        message: Text("If it is the coaching or the reminders you want gone, both are switches rather than a deletion.", tableName: "Data"))
    } header: {
      Text("Lighter options", tableName: "Data")
    }
  }
}

/// What deleting on this device leaves alone, said before anything is confirmed.
private struct DeleteVaultStays: View {
  var body: some View {
    Section {
      DeleteVaultOption(
        title: Text("The copy at your sync location", tableName: "Data"),
        message: Text(
          "Memoir stops syncing and leaves what it already sent where it is, so your other devices keep their data. Remove it with the storage’s own tools if you want it gone there too.",
          tableName: "Data"))
      DeleteVaultOption(
        title: Text("Keys and connections", tableName: "Data"),
        message: Text(
          "The vault’s keys stay in your keychain, since your other devices may still need them, and so do your AI provider key and sync sign-ins. Remove the provider key in AI Settings.",
          tableName: "Data"))
      DeleteVaultOption(
        title: Text("Apple Health and permissions", tableName: "Data"),
        message: Text(
          "Memoir never writes to Health, so nothing there changes. Health and notification permissions stay until you change them in Settings.", tableName: "Data"))
      DeleteVaultOption(
        title: Text("Archives you exported", tableName: "Data"),
        message: Text("They stay wherever you saved or shared them.", tableName: "Data"))
    } header: {
      Text("What stays", tableName: "Data")
    }
  }
}

private struct DeleteVaultOption: View {
  let title: Text
  let message: Text

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      title
      message.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      DeleteVaultView(context: context)
    }
    .shadowTheme()
  }
}

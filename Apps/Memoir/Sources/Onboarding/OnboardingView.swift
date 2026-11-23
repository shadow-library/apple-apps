import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowSyncRuntime
import SwiftUI
import UniformTypeIdentifiers

/// The first run of an empty vault (`features/onboarding/onboarding-screen.tsx`): no account, five steps, and the app with the first quest after them.
struct OnboardingView: View {
  @State private var model: OnboardingModel
  @State private var restore: RestoreModel
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?
  @Environment(MemoirVaultDeletion.self) private var deletion: MemoirVaultDeletion?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: OnboardingModel(context: context))
    _restore = State(initialValue: RestoreModel(context: context))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          header
          if restore.isUnfinished {
            OnboardingUnfinishedRestore(model: restore, deletion: deletion)
          } else {
            if model.offersDemo { OnboardingDemoOffer() }
            if model.offersDemo, restore.isOffered { OnboardingRestoreOffer(model: restore) }
            if model.offersDemo, restore.isEmpty, !restore.isSyncSettled {
              Text(
                "Restoring an export becomes possible once sync has finished checking your storage and found nothing there, or while sync is off.",
                tableName: "Onboarding"
              )
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
            }
          }
          ShadowCard {
            step.frame(maxWidth: .infinity, alignment: .leading)
          }
          footer
        }
        .padding(Spacing.space4)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .background(ShadowColor.surfaceApp)
      .navigationTitle(Text("Set up", tableName: "Onboarding"))
      .shadowScreen(.root)
    }
    .onChange(of: sync?.status, initial: true) { _, status in model.syncStatus = status ?? .off }
    .task(id: RestoreSyncKey(status: sync?.status, hasStarted: sync?.hasStarted == true)) {
      let sync = sync
      restore.syncSettled = { await RestoreModel.settled(sync) }
      await restore.refresh()
    }
    .fileImporter(isPresented: $restore.isPicking, allowedContentTypes: [.zip]) { result in Task { await restore.picked(result) } }
    .sheet(isPresented: Binding(get: { restore.isPresentingConfirmation }, set: { if !$0 { restore.cancel() } })) {
      RestoreConfirmation(model: restore)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ShadowSteps(
        current: model.step.rawValue, titles: OnboardingStep.allCases.map { Text(verbatim: OnboardingCopy.title($0)) },
        position: { position in Text("Step \(position.number) of \(position.count)", tableName: "Onboarding") })
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: OnboardingCopy.title(model.step)).shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Text(verbatim: OnboardingCopy.subtitle(model.step, startsOn: model.firstDay?.weekday, startsToday: model.startsToday))
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  @ViewBuilder
  private var step: some View {
    switch model.step {
    case .day: OnboardingDayStep(model: model)
    case .quest: OnboardingQuestStep(model: model)
    case .schedule: OnboardingScheduleStep(model: model)
    case .strictness: OnboardingStrictnessStep(model: model)
    case .ready: OnboardingReadyStep(model: model)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      if model.step == .ready, let hold = model.syncHold { OnboardingSyncHoldNotice(hold: hold) }
      HStack(spacing: Spacing.space3) {
        Button {
          model.back()
        } label: {
          Text("Back", tableName: "Onboarding")
        }
        .buttonStyle(.shadowBordered)
        .disabled(model.step == .day || model.isSaving)
        Spacer()
        if model.step == .ready {
          Button {
            Task { await model.finish() }
          } label: {
            Text("Create it and start", tableName: "Onboarding")
          }
          .buttonStyle(.shadowFilled)
          .shadowLoading(model.isSaving)
          .disabled(model.isSaving || model.syncHold != nil || restore.isUnfinished)
          .keyboardShortcut(.defaultAction)
        } else {
          Button {
            model.advance()
          } label: {
            model.step.next == .ready ? Text("Review", tableName: "Onboarding") : Text("Continue", tableName: "Onboarding")
          }
          .buttonStyle(.shadowFilled)
          .keyboardShortcut(.defaultAction)
        }
      }
      Text(verbatim: OnboardingCopy.footNote(model.step, problem: model.problem))
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

/// Why "Create it and start" waits: sync is bringing another device's data, which onboarding would otherwise overwrite.
struct OnboardingSyncHoldNotice: View {
  let hold: OnboardingSyncHold

  var body: some View {
    switch hold {
    case .arriving:
      ShadowCallout(
        Text("Your other device’s data is still arriving", tableName: "Onboarding"),
        message: Text("Memoir opens with it as soon as sync finishes, so there may be nothing to set up here. Wait a moment before creating anything.", tableName: "Onboarding"),
        intent: .info, systemImage: "arrow.triangle.2.circlepath")
    case .awaitingKey:
      ShadowCallout(
        Text("This device is waiting for your data’s key", tableName: "Onboarding"),
        message: Text("Your other device’s data is still arriving. Finish adding this device in Sync, and Memoir opens with your data instead.", tableName: "Onboarding"),
        intent: .warning, systemImage: "key")
    }
  }
}

/// The demo instead of setting up; leaving it shows onboarding again from its first step, since the owner's vault is still empty.
struct OnboardingDemoOffer: View {
  @Environment(\.demoEntry) private var entry

  var body: some View {
    if entry != nil {
      ShadowCallout(
        Text("Just looking?", tableName: "Onboarding"),
        message: Text(
          "Try the demo: a sample week with answers scripted on this device. Nothing is set up here, and leaving the demo brings you back to this step.",
          tableName: "Onboarding"),
        intent: .info, systemImage: "play.circle"
      ) {
        TryDemoButton()
      }
    }
  }
}

private struct RestoreSyncKey: Equatable {
  let status: SyncStatus?
  let hasStarted: Bool
}

/// A restore that committed some stores and not the main one: setting up beside its data would leave a vault half restored, so the only way on is to
/// erase what it left, which opens the vault again empty.
struct OnboardingUnfinishedRestore: View {
  @Bindable var model: RestoreModel
  let deletion: MemoirVaultDeletion?

  var body: some View {
    ShadowCallout(
      Text("A restore didn’t finish", tableName: "Onboarding"),
      message: Text(
        "Part of an export reached this device before the restore stopped. Erase it to start again empty, then restore the export again or set up from the start.",
        tableName: "Onboarding"),
      intent: .warning, systemImage: "exclamationmark.triangle"
    ) {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Button(role: .destructive) {
          guard let deletion else { return }
          Task { await model.eraseUnfinished { () throws(VaultDeletionError) in try await deletion.delete() } }
        } label: {
          Text("Erase the unfinished restore and try again", tableName: "Onboarding")
        }
        .buttonStyle(.shadowBordered)
        .shadowLoading(model.isErasing)
        .disabled(model.isErasing || deletion == nil)
        if let failure = model.eraseFailure { ShadowValidationMessage(failure.text) }
      }
    }
  }
}

/// Restoring an export instead of setting up, offered only while the vault is empty and sync has settled.
struct OnboardingRestoreOffer: View {
  @Bindable var model: RestoreModel

  var body: some View {
    ShadowCallout(
      Text("Coming back with an export?", tableName: "Onboarding"),
      message: Text(
        "Restore the archive you exported from Memoir: everything in it comes back on this device, instead of setting up from the start.", tableName: "Onboarding"),
      intent: .info, systemImage: "arrow.down.doc"
    ) {
      Button {
        model.isPicking = true
      } label: {
        Text("Restore from an export…", tableName: "Onboarding")
      }
      .buttonStyle(.shadowBordered)
      .shadowLoading(model.stage == .reading)
      .disabled(model.stage == .reading)
    }
  }
}

/// A labelled field with its helper and, once touched, its problem.
struct OnboardingField<Content: View>: View {
  let label: Text
  var helper: Text?
  var problem: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      content
      if let problem {
        ShadowValidationMessage(Text(verbatim: problem))
      } else if let helper {
        helper.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

/// A choice drawn as a card, as the reference's card radio groups.
struct OnboardingChoice<Label: View>: View {
  let isSelected: Bool
  let action: () -> Void
  @ViewBuilder let label: Label

  var body: some View {
    Button(action: action) {
      label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.space3)
        .background(isSelected ? ShadowColor.accentSoft : ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(isSelected ? ShadowColor.accent : ShadowColor.borderSubtle))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    OnboardingView(context: context)
      .environment(SyncRuntimes(identity: .memoir, factory: nil))
      .environment(SettingsTabs())
      .shadowTheme()
  }
}

import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowSyncRuntime
import SwiftUI

/// The first run of an empty vault (`features/onboarding/onboarding-screen.tsx`): no account, five steps, and the app with the first quest after them.
struct OnboardingView: View {
  @State private var model: OnboardingModel
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: OnboardingModel(context: context))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          header
          if model.offersDemo { OnboardingDemoOffer() }
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
          .disabled(model.isSaving || model.syncHold != nil)
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

import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/ChecksPanel.tsx:276-414.
struct FindingCard: View {
  let finding: ReviewFinding
  let remedy: ReviewRemedy?
  let answerable: Bool
  let busy: Bool
  let kind: ChapterReviewKind
  let isApproved: Bool
  let onAnswer: (ReviewRemedyAction, String?) async -> Bool
  let onClear: () async -> Bool
  @State private var form: ReviewRemedyAction?
  @State private var reason = ""
  @State private var confirmingUndo = false

  var body: some View {
    let state = ChecksDisplay.state(remedy)
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space2) {
        ShadowBadge(Text(verbatim: ChecksDisplay.severityLabel(finding.severity)), intent: ChecksDisplay.severityIntent(finding.severity))
        Text(verbatim: ChecksDisplay.categoryLabel(finding.category)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      }
      Text(verbatim: finding.text).shadowFont(.body).foregroundStyle(state == .settled ? ShadowColor.textSecondary : ShadowColor.textPrimary)
      if let evidence = finding.evidence, !evidence.isEmpty {
        Text(verbatim: "“\(evidence)”").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).italic()
      }
      if let remedy { remedyLine(remedy) }
      if answerable, state == .open { answers }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md))
    .disabled(busy)
    .confirmationDialog(Text("Undo and reopen this blocking finding?", tableName: "Checks"), isPresented: $confirmingUndo) {
      Button(role: .destructive) {
        Task { _ = await onClear() }
      } label: {
        Text("Undo and Withdraw Approval", tableName: "Checks")
      }
      Button(role: .cancel) {
      } label: {
        Text("Keep It", tableName: "Checks")
      }
    } message: {
      Text("This withdraws your approval of this chapter. The finding holds the next chapter again until you answer it.", tableName: "Checks")
    }
  }

  private func remedyLine(_ remedy: ReviewRemedy) -> some View {
    HStack(spacing: Spacing.space2) {
      Text(verbatim: ChecksDisplay.remedyNote(remedy, severity: finding.severity)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      if answerable {
        Button {
          if ChecksDisplay.confirmsUndo(approved: isApproved, kind: kind, finding: finding, remedy: remedy) { confirmingUndo = true } else { Task { _ = await onClear() } }
        } label: {
          Text("Undo", tableName: "Checks")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  @ViewBuilder
  private var answers: some View {
    if let action = form {
      reasonForm(action)
    } else {
      HStack(spacing: Spacing.space2) {
        Button {
          Task { _ = await onAnswer(.fixingMyself, nil) }
        } label: {
          Text("I'll Fix It Myself", tableName: "Checks")
        }
        Button {
          open(.dismissed)
        } label: {
          Text("Dismiss…", tableName: "Checks")
        }
        if ChecksDisplay.offersOverride(finding) {
          Button {
            open(.overridden)
          } label: {
            Text("Override…", tableName: "Checks")
          }
        }
      }
    }
  }

  private func reasonForm(_ action: ReviewRemedyAction) -> some View {
    let dismissing = action == .dismissed
    let canSubmit = !dismissing || !reason.allSatisfy(\.isWhitespace)
    return VStack(alignment: .leading, spacing: Spacing.space2) {
      TextField(
        text: $reason, prompt: dismissing ? Text("Why? e.g. the repetition is deliberate", tableName: "Checks") : Text("Why is it intended? (optional)", tableName: "Checks")
      ) {
        dismissing ? Text("Why dismiss this finding?", tableName: "Checks") : Text("Why is it intended?", tableName: "Checks")
      }
      .onSubmit { submit(action, canSubmit: canSubmit) }
      HStack(spacing: Spacing.space2) {
        Button {
          submit(action, canSubmit: canSubmit)
        } label: {
          dismissing ? Text("Dismiss", tableName: "Checks") : Text("Override", tableName: "Checks")
        }
        .disabled(!canSubmit)
        Button(role: .cancel) {
          form = nil
        } label: {
          Text("Cancel", tableName: "Checks")
        }
      }
    }
  }

  private func open(_ action: ReviewRemedyAction) {
    reason = ""
    form = action
  }

  private func submit(_ action: ReviewRemedyAction, canSubmit: Bool) {
    guard canSubmit else { return }
    Task {
      if await onAnswer(action, reason) { form = nil }
    }
  }
}

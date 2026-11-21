import NovelForgeCore
import ShadowAI
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/ChecksPanel.tsx:1-274: the four kinds with their status, then the selected kind's latest review.
/// The reference's compliance and metric blocks are not shown: the native review records store neither.
struct ChecksPanel: View {
  let model: ChecksModel
  let phases: [ChapterReviewKind: ReviewJobPhase]
  let jobsUnavailable: Bool
  let isApproved: Bool
  let run: (ChapterReviewKind, Pace?) -> Void
  @State private var kind = ChapterReviewKind.judge
  @State private var pace: Pace?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      VStack(spacing: Spacing.space2) {
        ForEach(ChecksDisplay.kinds, id: \.self) { candidate in kindRow(candidate) }
      }
      if let review = model.reviews.value, review.unreadable > 0 { unavailable(review.unreadable) }
      detail
    }
  }

  private func kindRow(_ candidate: ChapterReviewKind) -> some View {
    let review = model.latest(candidate)
    let status = ChecksDisplay.status(review, job: phases[candidate])
    return Button {
      kind = candidate
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text(verbatim: ChecksDisplay.label(candidate)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: ChecksDisplay.subline(review)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
        Spacer()
        ShadowBadge(Text(verbatim: status.label), intent: status.intent)
      }
      .padding(Spacing.space3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(candidate == kind ? ShadowColor.accentSoft : ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md))
      .contentShape(RoundedRectangle(cornerRadius: Radius.md))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(candidate == kind ? .isSelected : [])
  }

  private func unavailable(_ count: Int) -> some View {
    ShadowCallout(
      Text("Unavailable", tableName: "Checks"), message: Text("\(count) saved reviews can't be read by this version of Novel Forge.", tableName: "Checks"), intent: .warning
    ) {
      EmptyView()
    }
  }

  @ViewBuilder
  private var detail: some View {
    let review = model.latest(kind)
    VStack(alignment: .leading, spacing: Spacing.space3) {
      if let review { reviewHeader(review) }
      if let review {
        reviewBody(review)
      } else {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("No \(ChecksDisplay.noun(kind)) yet", tableName: "Checks").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: ChecksDisplay.description(kind)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      runner(review)
    }
  }

  private func reviewHeader(_ review: ChapterReviewView) -> some View {
    let disposition = ChecksDisplay.disposition(review)
    return VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack {
        Text(verbatim: ChecksDisplay.label(kind)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ShadowBadge(Text(verbatim: disposition.label), intent: disposition.intent)
      }
      Text(verbatim: ChecksDisplay.meta(review)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  @ViewBuilder
  private func reviewBody(_ review: ChapterReviewView) -> some View {
    let record = review.review
    if review.stale {
      ShadowCallout(Text(verbatim: ChecksDisplay.staleNotice()), intent: .warning) {
        if canRun(kind) {
          Button {
            run(kind, pace)
          } label: {
            Text("Review the Current Text", tableName: "Checks")
          }
        }
      }
    }
    if record.disposition == .known(.failed) {
      ShadowCallout(
        Text("Not assessed", tableName: "Checks"), message: Text("This review couldn't be read, so it checked nothing. Run it again.", tableName: "Checks"), intent: .neutral
      ) {
        EmptyView()
      }
    } else if review.openFindings == 0 {
      ShadowCallout(Text("No issue detected", tableName: "Checks"), intent: .success) { EmptyView() }
    }
    if let note = record.note, !note.isEmpty { Text(verbatim: note).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
    if !record.findings.isEmpty { findings(review) }
    if !record.checked.isEmpty { checked(record.checked) }
  }

  private func findings(_ review: ChapterReviewView) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Findings · \(review.openFindings) open", tableName: "Checks").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      ForEach(ChecksDisplay.groups(review.review.findings), id: \.severity) { group in
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Text(verbatim: ChecksDisplay.groupLabel(group.severity, count: group.findings.count)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          ForEach(group.findings, id: \.id) { finding in card(finding, review: review) }
        }
      }
    }
  }

  private func card(_ finding: ReviewFinding, review: ChapterReviewView) -> some View {
    FindingCard(
      finding: finding, remedy: review.remedies[finding.id], answerable: ChecksDisplay.isAnswerable(review), busy: model.busyFinding == finding.id,
      kind: kind, isApproved: isApproved,
      onAnswer: { action, reason in await model.answer(review, finding: finding, action: action, reason: reason) },
      onClear: { await model.clear(review, finding: finding) })
  }

  private func checked(_ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text("What was checked", tableName: "Checks").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      ForEach(items, id: \.self) { item in Label(title: { Text(verbatim: item) }, icon: { Image(systemName: "checkmark") }).shadowFont(.footnote) }
      if ChecksDisplay.isModelKind(kind) {
        Text("A model does these checks. “No issue detected” means it found nothing, not that nothing is there.", tableName: "Checks").shadowFont(.caption)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func canRun(_ kind: ChapterReviewKind) -> Bool {
    guard model.starting == nil else { return false }
    return ChecksDisplay.isModelKind(kind) ? phases[kind] == nil && !jobsUnavailable : true
  }

  @ViewBuilder
  private func runner(_ review: ChapterReviewView?) -> some View {
    if let phase = phases[kind] {
      HStack(spacing: Spacing.space2) {
        ProgressView().controlSize(.small)
        phaseText(phase)
      }
    } else {
      HStack(spacing: Spacing.space3) {
        Button {
          run(kind, pace)
        } label: {
          if model.starting == kind { ProgressView().controlSize(.small) } else { Text(verbatim: ChecksDisplay.runLabel(kind, hasReview: review != nil)) }
        }
        .disabled(!canRun(kind))
        if ChecksDisplay.isModelKind(kind) { pacePicker }
      }
      if ChecksDisplay.isModelKind(kind), jobsUnavailable {
        Text("Unavailable", tableName: "Checks").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func phaseText(_ phase: ReviewJobPhase) -> Text {
    switch phase {
    case .queued(.startsHere): Text("\(ChecksDisplay.label(kind)) is queued — it starts in a moment.", tableName: "Checks")
    case .queued(.permission): Text("\(ChecksDisplay.label(kind)) is waiting for your permission to send this novel's text.", tableName: "Checks")
    case .queued(.elsewhere): Text("\(ChecksDisplay.label(kind)) is queued — it starts when the device that runs jobs takes it, or when you run it here.", tableName: "Checks")
    case .running: Text("\(ChecksDisplay.label(kind)) is reading the chapter — this can take a minute.", tableName: "Checks")
    }
  }

  private var pacePicker: some View {
    Picker(selection: $pace) {
      Text("Novel's Pace", tableName: "Checks").tag(Pace?.none)
      ForEach(Pace.allCases, id: \.self) { option in Text(verbatim: option.displayName).tag(Pace?.some(option)) }
    } label: {
      Text("Pace for this review", tableName: "Checks")
    }
    .fixedSize()
  }
}

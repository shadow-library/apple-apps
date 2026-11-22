import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chat/TurnProposalCard.tsx:110-211
struct ChatProposalCard: View {
  let model: ChatProposalCardModel
  let presenter: ChatCardsPresenter

  var body: some View {
    content
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(ShadowColor.borderSubtle))
      .task(id: model.generation) { await model.observe() }
      .onChange(of: model.revert.isPresented) { _, presented in if presented { presenter.present(model.revert) } }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity)
    case .failed(let error):
      ChatCardUnavailable(message: error.text) { model.retryReading() }
    case .loaded(let snapshot):
      if snapshot.isUnavailable && snapshot.card == nil {
        ChatCardUnavailable(message: Text("They are not up to date on this device yet. Try again after syncing.", tableName: "ChatCards")) { model.retryReading() }
      } else if snapshot.card == nil {
        absent(snapshot)
      } else if snapshot.card?.kind == .known(.chapterPlan) {
        ChatPlanCard(model: model, presenter: presenter)
      } else {
        card(snapshot)
      }
    }
  }

  private func absent(_ snapshot: ChatCardSnapshot) -> some View {
    Label {
      if snapshot.state == nil && snapshot.decision == nil {
        Text("These suggested changes haven't arrived on this device yet.", tableName: "ChatCards")
      } else {
        Text("These suggested changes are stored in a form this version cannot read.", tableName: "ChatCards")
      }
    } icon: {
      Image(systemName: "sparkles")
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.textSecondary)
  }

  private func card(_ snapshot: ChatCardSnapshot) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      HStack(spacing: Spacing.space2) {
        Image(systemName: "sparkles").foregroundStyle(ShadowColor.accentText)
        Text(verbatim: ChatOp.title(of: model.ops)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ChatCardStatusBadge(status: model.status)
        if snapshot.isAutomatic { ShadowBadge(Text("auto", tableName: "ChatCards"), intent: .info) }
      }
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ForEach(model.ops, id: \.index) { op in
          ChatCardOpRow(model: model, op: op, entry: snapshot.state(of: op.index))
        }
      }
      ForEach(snapshot.card?.warnings ?? [], id: \.self) { warning in
        Label {
          Text(verbatim: warning)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.warningText)
      }
      if model.status == .conflicted {
        Text(verbatim: ChatCardsErrors.conflicted).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if model.status == .superseded {
        Text("A newer suggestion replaced this one.", tableName: "ChatCards").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if let notice = model.notice {
        ShadowCallout(Text(verbatim: notice.error.headline), message: notice.error.detail.map { Text(verbatim: $0) }, intent: .warning) { EmptyView() }
      }
      actions
    }
  }

  @ViewBuilder
  private var actions: some View {
    if model.canDiscard || model.canRevert {
      HStack(spacing: Spacing.space2) {
        if model.isPending {
          Button {
            Task { await model.apply() }
          } label: {
            Text(verbatim: model.applyTitle)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canApply)
        }
        if model.canDiscard {
          Button {
            presenter.discarding = model
          } label: {
            Text("Discard", tableName: "ChatCards")
          }
          .buttonStyle(.bordered)
        }
        if model.canRevert {
          Button(role: .destructive) {
            model.openRevert()
          } label: {
            Text("Revert", tableName: "ChatCards")
          }
          .buttonStyle(.bordered)
        }
        if model.isBusy { ProgressView().controlSize(.small) }
      }
    }
  }
}

/// One change of a card: whether it is included, what it is, and what applying it did (TurnProposalCard.tsx:123-149).
struct ChatCardOpRow: View {
  let model: ChatProposalCardModel
  let op: ChatOp
  let entry: ProposalChangeEntryState?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        if model.isPending {
          Button {
            model.toggle(op)
          } label: {
            Image(systemName: model.isSelected(op) ? "checkmark.square.fill" : "square")
              .foregroundStyle(model.isSelected(op) ? ShadowColor.accentText : ShadowColor.textTertiary)
          }
          .buttonStyle(.plain)
          .disabled(!model.isSelectable(op) || model.isBusy)
          .accessibilityLabel(Text("Include \(op.subject)", tableName: "ChatCards"))
          .accessibilityAddTraits(model.isSelected(op) ? .isSelected : [])
        }
        Button {
          model.toggleExpanded(op.index)
        } label: {
          Text(verbatim: op.subject).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .disabled(!op.isReadable)
        .accessibilityValue(model.isExpanded(op) ? Text("expanded", tableName: "ChatCards") : Text("collapsed", tableName: "ChatCards"))
        if op.isAction { ShadowBadge(Text("action", tableName: "ChatCards"), intent: .info) }
        Spacer(minLength: Spacing.space2)
        if let entry, !model.isPending { ChatEntryBadge(state: entry) }
      }
      if model.isPending && op.isJobAction {
        Text("Not yet available.", tableName: "ChatCards").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      } else if model.isPending && op.isGuarded {
        Text("Applies only when you select it deliberately.", tableName: "ChatCards").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      if op.isReadable && model.isExpanded(op) {
        if op.isPassageRewrite { ChatPassageDiff(op: op) } else { ChatOpBodyView(fields: ChatOpBody(op)) }
      }
      if let code = model.failureCode(of: op.index) {
        Text(verbatim: "\(ChatCardsErrors.failure(code)) (\(code))").shadowFont(.caption).foregroundStyle(ShadowColor.dangerText)
      }
    }
    .padding(.vertical, Spacing.space1)
    .opacity(model.isPending && !model.isSelected(op) ? 0.7 : 1)
  }
}

/// TurnProposalCard.tsx:36-52: the chapter's words a rewrite takes out, then the words it puts in.
struct ChatPassageDiff: View {
  let op: ChatOp

  var body: some View {
    let diff = op.passageDiff
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: "− \(diff.removed)").strikethrough().foregroundStyle(ShadowColor.dangerText)
      if !diff.added.isEmpty { Text(verbatim: "+ \(diff.added)").foregroundStyle(ShadowColor.successText) }
    }
    .shadowFont(.callout)
    .textSelection(.enabled)
    .padding(Spacing.space3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }
}

/// apps/novel-forge-web/src/features/proposals/ChangeOpBody.tsx:40-67
struct ChatOpBodyView: View {
  let fields: ChatOpBody

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if let rationale = fields.rationale { Text(verbatim: rationale).shadowFont(.callout).italic().foregroundStyle(ShadowColor.textSecondary) }
      if !fields.inline.isEmpty {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space1) {
          ForEach(fields.inline, id: \.key) { field in
            GridRow {
              Text(verbatim: field.key).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
              Text(verbatim: field.value).shadowFont(.footnote).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
            }
          }
        }
      }
      ForEach(fields.prose, id: \.key) { field in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text(verbatim: field.key).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
          ProseView(markdown: field.value)
        }
      }
    }
    .padding(Spacing.space3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }
}

struct ChatCardStatusBadge: View {
  let status: ChatCardStatus

  var body: some View {
    switch status {
    case .pending: ShadowBadge(Text("pending", tableName: "ChatCards"), intent: .warning)
    case .conflicted: ShadowBadge(Text("conflicted", tableName: "ChatCards"), intent: .danger)
    case .applied: ShadowBadge(Text("applied", tableName: "ChatCards"), intent: .success)
    case .reverted: ShadowBadge(Text("reverted", tableName: "ChatCards"), intent: .neutral)
    case .discarded: ShadowBadge(Text("discarded", tableName: "ChatCards"), intent: .neutral)
    case .superseded: ShadowBadge(Text("superseded", tableName: "ChatCards"), intent: .neutral)
    case .absent, .unknown: EmptyView()
    }
  }
}

/// TurnProposalCard.tsx:17-22
struct ChatEntryBadge: View {
  let state: ProposalChangeEntryState

  var body: some View {
    switch state {
    case .applied: ShadowBadge(Text("applied", tableName: "ChatCards"), intent: .success)
    case .declined, .notApplied: ShadowBadge(Text("declined", tableName: "ChatCards"), intent: .neutral)
    case .failed: ShadowBadge(Text("failed", tableName: "ChatCards"), intent: .danger)
    case .pending: ShadowBadge(Text("waiting to run", tableName: "ChatCards"), intent: .warning)
    case .reverted: ShadowBadge(Text("undone", tableName: "ChatCards"), intent: .neutral)
    case .awaiting: ShadowBadge(Text("arriving", tableName: "ChatCards"), intent: .info)
    case .unreadable, .unrecognised, .uncertain: ShadowBadge(Text("unknown", tableName: "ChatCards"), intent: .warning)
    }
  }
}

struct ChatCardUnavailable: View {
  let message: Text
  let retry: () -> Void

  var body: some View {
    ShadowCallout(Text("These changes are unavailable", tableName: "ChatCards"), message: message, intent: .warning) {
      Button {
        retry()
      } label: {
        Text("Try Again", tableName: "ChatCards")
      }
    }
  }
}

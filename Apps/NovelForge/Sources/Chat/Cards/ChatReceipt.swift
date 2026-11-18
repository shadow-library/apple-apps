import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// TurnReceipt.tsx:26-68 with the panel's applied changes (ProgressPanel.tsx:140-186) inline: the receipt line, then each change with undo or redo.
struct ChatReceipt: View {
  let model: ChatReceiptModel
  let presenter: ChatCardsPresenter

  var body: some View {
    content
      .padding(Spacing.space3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
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
      if snapshot.card == nil {
        ChatCardUnavailable(message: Text("They are not up to date on this device yet. Try again after syncing.", tableName: "ChatCards")) { model.retryReading() }
      } else {
        receipt
      }
    }
  }

  private var receipt: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ForEach(model.changes, id: \.index) { op in ChatReceiptRow(model: model, op: op) }
        }
        .padding(.top, Spacing.space2)
      } label: {
        HStack(spacing: Spacing.space2) {
          Image(systemName: "checkmark.circle").foregroundStyle(ShadowColor.successText)
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: model.title).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
            if let detail = model.detail { Text(verbatim: detail).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary) }
          }
        }
      }
      if model.canUndoAll {
        Button {
          model.undoAll()
        } label: {
          Text("Undo All", tableName: "ChatCards")
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

struct ChatReceiptRow: View {
  let model: ChatReceiptModel
  let op: ChatOp

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        Text(verbatim: op.subject)
          .shadowFont(.callout)
          .foregroundStyle(ShadowColor.textPrimary)
          .strikethrough(model.state(of: op) == .reverted)
        if model.isIdea(op) { ShadowBadge(Text("Forge's idea", tableName: "ChatCards"), intent: .accent) }
        Spacer(minLength: Spacing.space2)
        if let state = model.state(of: op), state != .applied { ChatEntryBadge(state: state) }
        if model.busy == op.index { ProgressView().controlSize(.small) }
        if model.canToggle(op) {
          Button {
            Task { await model.toggle(op) }
          } label: {
            if model.state(of: op) == .applied { Text("Undo", tableName: "ChatCards") } else { Text("Redo", tableName: "ChatCards") }
          }
          .buttonStyle(.borderless)
          .disabled(model.isLocked)
        }
      }
      if let leader = model.leader(of: op) {
        let name = model.subject(of: leader)
        Text("Moves with “\(name)”.", tableName: "ChatCards").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      if let failure = model.failure(of: op) { Text(verbatim: failure).shadowFont(.caption).foregroundStyle(ShadowColor.dangerText) }
      if let prompt = model.prompt, prompt.index == op.index { promptView(prompt) }
      if let notice = model.notices[op.index] { noticeView(notice) }
    }
  }

  // progress-panel-view.ts:587-592
  private func promptView(_ prompt: ChatChangePrompt) -> some View {
    let count = prompt.steps.count
    return ShadowCallout(Text(verbatim: promptTitle(prompt)), intent: .info) {
      HStack(spacing: Spacing.space2) {
        Button {
          Task { await model.confirmPrompt() }
        } label: {
          switch (prompt.kind, prompt.direction) {
          case (.changedDeclined, _): Text("Go Ahead", tableName: "ChatCards")
          case (.dependencies, .undo): Text("Undo These \(count)", tableName: "ChatCards")
          case (.dependencies, .redo): Text("Redo These \(count)", tableName: "ChatCards")
          }
        }
        Button {
          model.cancelPrompt()
        } label: {
          Text("Cancel", tableName: "ChatCards")
        }
      }
      .disabled(model.isLocked)
    }
  }

  private func promptTitle(_ prompt: ChatChangePrompt) -> String {
    let moved = prompt.moved.map(model.subject(of:))
    switch prompt.kind {
    case .changedDeclined:
      let lead = String(
        localized: "Changes left out of this reply have changed since, perhaps on another device. Go ahead, treating them as never applied?", table: "ChatCards")
      return lead + ChatChangeCopy.alreadyMoved(prompt.direction, moved)
    case .dependencies:
      return ChatChangeCopy.dependencies(prompt.direction, labels: prompt.before.map(model.subject(of:)), moved: moved)
    }
  }

  private func noticeView(_ notice: ChatCardNotice) -> some View {
    ShadowCallout(Text(verbatim: notice.error.headline), message: notice.error.detail.map { Text(verbatim: $0) }, intent: .warning) {
      if case .redoTwin? = notice.recovery {
        Button {
          Task { await model.recover(op.index) }
        } label: {
          Text("Redo the Other Change", tableName: "ChatCards")
        }
        .disabled(model.isLocked)
      }
    }
  }
}

import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/routes/novels/$novelId/chat.tsx:57-152, from the toolbar as ChatColumn.tsx:838-840 reaches it from the chat header.
struct ChatChangesSheet: View {
  let chats: ChatNovelModel
  @State private var model: ChatChangesModel?

  var body: some View {
    Group {
      if let model { ChatChangesList(chats: chats, model: model) }
    }
    .onAppear {
      guard model == nil else { return }
      model = ChatChangesModel(context: chats.context, writer: CoreChatProposalWriter(store: chats.context.store))
    }
  }
}

private struct ChatChangesList: View {
  let chats: ChatNovelModel
  let model: ChatChangesModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      if let report = model.report { reportView(report) }
      content
    }
    .shadowSheetHeader(
      Text("Change history", tableName: "ChatChanges"),
      subtitle: Text("Everything the chats changed, newest first. Undo one change, or roll the novel back to a point.", tableName: "ChatChanges"),
      cancel: ShadowSheetCancel(Text("Close", tableName: "ChatChanges"), isDisabled: model.isLocked, action: { dismiss() })
    )
    .shadowSheetStyle(.form)
    .chatRevertFlow(model.revert)
    .task(id: model.generation) { await model.observe() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 240)
    case .failed(let error):
      ShadowContentUnavailable(Text("The change history could not be read", tableName: "ChatChanges"), kind: .error, message: error.text) {
        Button {
          model.retry()
        } label: {
          Text("Try Again", tableName: "ChatChanges")
        }
      }
      .frame(maxWidth: .infinity, minHeight: 240)
    case .loaded(let snapshot):
      if let page = snapshot.page.value {
        list(page)
      } else {
        ShadowContentUnavailable(
          Text("The change history is unavailable", tableName: "ChatChanges"), kind: .error,
          message: Text("It is not up to date on this device yet. Try again after syncing.", tableName: "ChatChanges")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
      }
    }
  }

  @ViewBuilder
  private func list(_ page: ChatChangePage) -> some View {
    if page.changes.isEmpty {
      ShadowContentUnavailable(Text("No applied changes yet", tableName: "ChatChanges"), systemImage: "arrow.uturn.backward.circle")
        .frame(maxWidth: .infinity, minHeight: 240)
    } else {
      List {
        ForEach(page.changes, id: \.state.proposal) { change in
          ChatChangeRow(change: change, model: model, source: source(change.session))
        }
        if model.hasMore {
          Button {
            model.showMore()
          } label: {
            Text("Show Earlier Changes", tableName: "ChatChanges")
          }
          .buttonStyle(.borderless)
          .frame(maxWidth: .infinity)
        }
      }
      .listStyle(.plain)
      .frame(minHeight: 320)
    }
  }

  // chat.tsx:84-85
  private func reportView(_ report: ChatChangesReport) -> some View {
    ShadowCallout(Text(verbatim: ChatChangesText.report(report)), intent: report.isStopped ? .warning : .success) {
      Button {
        model.dismissReport()
      } label: {
        Text("OK", tableName: "ChatChanges")
      }
    }
  }

  private func source(_ session: ChatProposalSession) -> String {
    switch session {
    case .none: String(localized: "no chat", table: "ChatChanges")
    case .deleted: String(localized: "a deleted chat", table: "ChatChanges")
    case .live(let id), .unknown(let id): chats.overview(of: id) == nil ? String(localized: "another chat", table: "ChatChanges") : chats.title(of: id)
    }
  }
}

struct ChatChangeRow: View {
  let change: ChatChange
  let model: ChatChangesModel
  let source: String

  var body: some View {
    let lines = ChatChangeLines.lines(of: change)
    let summary = ChatChangeLines.summary(of: change)
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        if change.isReverted {
          ShadowBadge(Text("undone", tableName: "ChatChanges"), intent: .neutral)
        } else {
          ShadowBadge(Text("applied", tableName: "ChatChanges"), intent: .success)
        }
        if change.record?.application?.automatic == true { ShadowBadge(Text("auto", tableName: "ChatChanges"), intent: .info) }
        Spacer(minLength: Spacing.space2)
        Text(change.applied.date, format: .relative(presentation: .named)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      Text(verbatim: summary)
        .shadowFont(.callout)
        .foregroundStyle(ShadowColor.textPrimary)
        .strikethrough(change.isReverted)
      if !change.refs.isEmpty && summary != change.refs.joined(separator: ", ") {
        Text(verbatim: change.refs.joined(separator: " · ")).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary).lineLimit(2)
      }
      Text(verbatim: source).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      if !lines.isEmpty {
        DisclosureGroup {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            ForEach(lines) { line in ChatChangeLineView(line: line) }
          }
        } label: {
          Text(verbatim: ChatChangesText.count(lines)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      HStack(spacing: Spacing.space3) {
        if change.isRevertible {
          Button {
            model.revert(change)
          } label: {
            Text("Undo", tableName: "ChatChanges")
          }
          .disabled(!model.canRevert(change))
        }
        if !change.isReverted {
          Button {
            model.rollBack(to: change)
          } label: {
            Text("Roll Back to Here", tableName: "ChatChanges")
          }
          .disabled(!model.canRollBack(to: change))
        }
      }
      .buttonStyle(.borderless)
    }
    .padding(.vertical, Spacing.space1)
  }
}

struct ChatChangeLineView: View {
  let line: ChatChangeLine

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        if line.isAction { Image(systemName: "bolt").foregroundStyle(ShadowColor.textSecondary).accessibilityLabel(Text("Action", tableName: "ChatChanges")) }
        Text(verbatim: line.subject).shadowFont(.footnote).foregroundStyle(ShadowColor.textPrimary).strikethrough(line.state == .reverted)
        Spacer(minLength: Spacing.space2)
        ChatEntryBadge(state: line.state)
      }
      if let carried = ChatChangesText.carried(line) {
        Text(verbatim: carried).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

enum ChatChangesText {
  static func report(_ report: ChatChangesReport) -> String {
    switch report {
    case .reverted:
      return String(localized: "The change was undone.", table: "ChatChanges")
    case .rolledBack(let result) where result.stoppedAt != nil || result.refusal != nil:
      let reason = result.refusal.map { ChatCardsErrors.presented($0, during: .revert).headline } ?? ""
      return String(localized: "Rolled back \(result.reverted.count) changes, then stopped: \(reason)", table: "ChatChanges")
    case .rolledBack(let result) where result.skipped.isEmpty:
      return String(localized: "Rolled back \(result.reverted.count) changes.", table: "ChatChanges")
    case .rolledBack(let result):
      return String(localized: "Rolled back \(result.reverted.count) changes (\(result.skipped.count) with only actions skipped).", table: "ChatChanges")
    }
  }

  static func count(_ lines: [ChatChangeLine]) -> String {
    let undone = lines.count { $0.state == .reverted }
    guard undone > 0 else { return String(localized: "\(lines.count) changes", table: "ChatChanges") }
    return String(localized: "\(lines.count) changes, \(undone) undone", table: "ChatChanges")
  }

  /// A carried rewrite holds no undo of its own and stands as its leader does (ChatChangeHistory's `carriedBy`).
  static func carried(_ line: ChatChangeLine) -> String? {
    guard let leader = line.carriers.first else { return nil }
    guard line.carriers.count > 1 else { return String(localized: "Moves with “\(leader)”.", table: "ChatChanges") }
    let names = line.carriers.map { "“\($0)”" }.joined(separator: ", ")
    return String(localized: "Moves with one of \(names).", table: "ChatChanges")
  }
}

import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import SwiftUI

enum ChatHistoryFilter: Hashable, CaseIterable {
  case active
  case archived
}

/// Every chat the author posted in, active or archived, with rename, archive and delete (apps/novel-forge-web/src/routes/novels/$novelId/chat.tsx:177-356).
/// The reference's search over titles and summaries is not kept: no summary is listed here.
struct ChatHistorySheet: View {
  let model: ChatNovelModel
  @State private var filter = ChatHistoryFilter.active
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Picker(selection: $filter) {
        Text("Active \(count(.active))", tableName: "Chat").tag(ChatHistoryFilter.active)
        Text("Archived \(count(.archived))", tableName: "Chat").tag(ChatHistoryFilter.archived)
      } label: {
        Text("Chat status", tableName: "Chat")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      content
    }
    .shadowSheetHeader(
      Text("History", tableName: "Chat"), subtitle: Text("Every conversation with Forge about this novel.", tableName: "Chat"),
      cancel: ShadowSheetCancel(Text("Close", tableName: "Chat"), action: { dismiss() })
    )
    .shadowSheetStyle(.form)
    .chatSessionDialogs(model, isActive: true)
  }

  @ViewBuilder
  private var content: some View {
    switch list(filter) {
    case .available(let sessions) where sessions.isEmpty:
      empty.frame(maxWidth: .infinity, minHeight: 240)
    case .available(let sessions):
      List(sessions, id: \.state.session) { overview in row(overview) }
        .listStyle(.plain)
        .frame(minHeight: 320)
    case .unavailable:
      ShadowContentUnavailable(
        Text("Chats are unavailable", tableName: "Chat"), kind: .error,
        message: Text("They are not up to date on this device yet. Try again after syncing.", tableName: "Chat")
      )
      .frame(maxWidth: .infinity, minHeight: 240)
    }
  }

  // chat.tsx:154-162
  @ViewBuilder
  private var empty: some View {
    switch filter {
    case .active:
      ShadowContentUnavailable(
        Text("No chats yet", tableName: "Chat"), systemImage: "bubble.left.and.bubble.right",
        message: Text("A chat is where you ask Forge to read, plan or rewrite anything in this novel.", tableName: "Chat"))
    case .archived:
      ShadowContentUnavailable(
        Text("No archived chats", tableName: "Chat"), systemImage: "archivebox",
        message: Text("Archiving a chat takes it off the active list without deleting anything it changed.", tableName: "Chat"))
    }
  }

  private func row(_ overview: ChatSessionOverview) -> some View {
    let session = overview.state.session
    return Button {
      guard overview.record != nil else { return }
      model.open(session)
      dismiss()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          if overview.record == nil {
            Text("This chat cannot be read by this version", tableName: "Chat").foregroundStyle(ShadowColor.warningText)
          } else {
            Text(verbatim: model.title(of: session)).foregroundStyle(ShadowColor.textPrimary).lineLimit(1)
          }
          if let updated = overview.state.updated {
            Text(updated.date, format: .relative(presentation: .named)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
        }
        Spacer(minLength: Spacing.space2)
        if session == model.current { ShadowBadge(Text("open", tableName: "Chat"), intent: .accent) }
        if overview.record?.mode == .known(.manual) { ShadowBadge(Text("manual", tableName: "Chat"), intent: .warning) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { ChatSessionActions(model: model, session: session) }
    .swipeActions {
      Button(role: .destructive) {
        model.deleting = session
      } label: {
        Label {
          Text("Delete Chat…", tableName: "Chat")
        } icon: {
          Image(systemName: "trash")
        }
      }
    }
  }

  private func list(_ filter: ChatHistoryFilter) -> Derived<[ChatSessionOverview]> {
    guard let snapshot = model.state.value else { return .available([]) }
    switch filter {
    case .active: return snapshot.active.sessions
    case .archived: return snapshot.archived.sessions
    }
  }

  private func count(_ filter: ChatHistoryFilter) -> Int {
    list(filter).value?.count ?? 0
  }
}

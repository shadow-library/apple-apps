import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import SwiftUI

/// One transcript message (apps/novel-forge-web/src/features/chat/ChatColumn.tsx:870-898): the author's on the right, the reply as prose with its tag line.
struct ChatMessageRow: View {
  let message: ChatTranscriptMessage
  let cost: ChatReplyCost?
  let inspect: (UUID) -> Void

  var body: some View {
    if let record = message.record {
      switch record.role {
      case .known(.user): authored(record)
      case .known(.assistant): reply(record)
      case .unknown: unreadable
      }
    } else {
      unreadable
    }
  }

  private func authored(_ record: ChatMessageRecord) -> some View {
    VStack(alignment: .trailing, spacing: Spacing.space1) {
      if let passages = record.contexts?.count, passages > 0 {
        Text("Comments on \(passages) passages", tableName: "Chat").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if !record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(verbatim: record.content)
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
          .textSelection(.enabled)
          .padding(Spacing.space3)
          .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      }
      Text(verbatim: ChatReplyTag.time(message.row.clock.date)).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, Spacing.space10)
  }

  private func reply(_ record: ChatMessageRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if !record.content.isEmpty { ProseView(markdown: record.content) }
      ChatReplyFooter(reply: record)
      Text(verbatim: ChatReplyTag.parts(of: record, cost: record.modelCalls == nil ? nil : cost, at: message.row.clock.date).joined(separator: " · "))
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button {
        inspect(record.id)
      } label: {
        Label {
          Text("Inspect Request", tableName: "Chat")
        } icon: {
          Image(systemName: "doc.text.magnifyingglass")
        }
      }
    }
  }

  private var unreadable: some View {
    Label {
      Text("This message cannot be read by this version.", tableName: "Chat")
    } icon: {
      Image(systemName: "exclamationmark.triangle")
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.warningText)
  }
}

/// What a reply did beyond its words: the note on changes that could not be saved, then its receipt, card and question (`Cards/ChatReplyCards`). Without
/// the session's cards context the reply only says that it changed the story or left suggestions.
struct ChatReplyFooter: View {
  let reply: ChatMessageRecord
  @Environment(\.chatCards) private var cards

  var body: some View {
    if let note = reply.applyNote {
      ShadowCallout(Text(verbatim: note), intent: .warning) { EmptyView() }
    }
    if let cards {
      ChatReplyCards(reply: reply, cards: cards)
    } else {
      if reply.appliedProposal != nil { caption(Text("Changed your story", tableName: "ChatCards"), systemImage: "checkmark.circle", color: ShadowColor.successText) }
      if reply.cardProposal != nil { caption(Text("Suggested changes", tableName: "ChatCards"), systemImage: "sparkles", color: ShadowColor.accentText) }
    }
  }

  private func caption(_ title: Text, systemImage: String, color: Color) -> some View {
    Label {
      title
    } icon: {
      Image(systemName: systemImage)
    }
    .shadowFont(.footnote)
    .foregroundStyle(color)
  }
}

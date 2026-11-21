import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/chat/WaitingTray.tsx:26-106; a card opens its own chat rather than being brought into this one. In regular width it
/// also lists the chapters' rows of Waiting on you (phase 8 decision 6), which never open the tray on their own; a compact chat leaves them to the iPhone home.
struct ChatWaitingTray: View {
  let tray: ChatTrayModel
  let chats: ChatNovelModel
  /// Nil on the opening composer, before a chat exists.
  let session: ChatSessionModel?
  @Environment(NovelNavigator.self) private var navigator
  @Environment(JobRuntimes.self) private var runtimes
  @State private var isOpen: Bool?
  @State private var pending = PendingModel()
  @State private var pendingActions = PendingActions()

  var body: some View {
    let items = tray.items
    let away = items.count { !isHere($0) }
    let chapters = chapterRows
    content(items, chapters: chapters, away: away)
      .onChange(of: away, initial: true) { previous, next in
        if next > previous { isOpen = nil }
      }
      .pendingObservation(pending, context: chats.context, isActive: navigator.layout == .regular)
      .pendingPresentations(pendingActions, context: chats.context)
  }

  private var chapterRows: [PendingItem] {
    guard navigator.layout == .regular else { return [] }
    let standing = runtimes.existing(for: chats.context.store)?.standing ?? .starting
    return pending.list(replica: chats.context.store.replica, standing: standing).chapters
  }

  @ViewBuilder
  private func content(_ items: [ChatTrayItem], chapters: [PendingItem], away: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if case .failed(let error) = tray.state {
        ShadowCallout(Text("Waiting on you could not be read", tableName: "ChatChanges"), message: error.text, intent: .warning) {
          Button {
            tray.retry()
          } label: {
            Text("Try Again", tableName: "ChatChanges")
          }
        }
      } else if tray.isUnavailable {
        Text("Cards waiting on you are not up to date on this device yet.", tableName: "ChatChanges").shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
      }
      if !items.isEmpty || !chapters.isEmpty {
        if isOpen ?? (away > 0) { expanded(items, chapters: chapters) } else { collapsed(items, chapters: chapters) }
      }
    }
  }

  private func collapsed(_ items: [ChatTrayItem], chapters: [PendingItem]) -> some View {
    var seen = Set<String>()
    let names = (items.map(ChatTrayText.short) + chapters.map(PendingDisplay.short)).filter { seen.insert($0).inserted }.joined(separator: " · ")
    return HStack(spacing: Spacing.space2) {
      ShadowBadge(count: items.count + chapters.count)
      Text("Waiting on you: \(names)", tableName: "ChatChanges").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(1).help(Text(verbatim: names))
      Spacer(minLength: Spacing.space2)
      Button {
        isOpen = true
      } label: {
        Text("Show", tableName: "ChatChanges")
      }
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, Spacing.space3)
  }

  private func expanded(_ items: [ChatTrayItem], chapters: [PendingItem]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack {
        Text("Waiting on you · \(items.count + chapters.count)", tableName: "ChatChanges").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        Spacer(minLength: Spacing.space2)
        Button {
          isOpen = false
        } label: {
          Text("Hide", tableName: "ChatChanges")
        }
        .buttonStyle(.borderless)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ForEach(items) { item in row(item) }
          ForEach(chapters) { item in PendingRow(item: item, context: chats.context, actions: pendingActions, chats: chats, here: session?.session) }
        }
      }
      .frame(maxHeight: 220)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Everything waiting on you", tableName: "ChatChanges"))
  }

  private func row(_ item: ChatTrayItem) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        ChatTrayText.chip(item.kind)
        Text(verbatim: ChatTrayText.title(item)).shadowFont(.callout).foregroundStyle(ShadowColor.textPrimary).lineLimit(1)
        Spacer(minLength: Spacing.space2)
        actions(item)
      }
      Text(verbatim: source(item)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).lineLimit(1)
      if let detail = ChatTrayText.detail(item.kind) {
        PresentedError(headline: detail, detail: ChatTrayText.code(item.kind)).text.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      if case .actions(_, .faulted(_, true)) = item.kind, case .proposal(let proposal) = item.target {
        HStack(spacing: Spacing.space2) {
          Button {
            Task { await tray.retryActions(proposal) }
          } label: {
            Text("Try Again", tableName: "ChatChanges")
          }
          .buttonStyle(.borderless)
          .disabled(tray.retrying != nil)
          if tray.retrying == proposal { ProgressView().controlSize(.small) }
        }
        if let notice = tray.retryNotices[proposal] { notice.text.shadowFont(.caption).foregroundStyle(ShadowColor.warningText) }
      }
    }
  }

  @ViewBuilder
  private func actions(_ item: ChatTrayItem) -> some View {
    if item.isPlan {
      Button {
        tray.revealPlans()
      } label: {
        Text("Open", tableName: "ChatChanges")
      }
      .buttonStyle(.borderless)
    } else if let chat = openable(item) {
      Button {
        show(item, in: chat)
      } label: {
        if isHere(item) { Text("Show", tableName: "ChatChanges") } else { Text("Open", tableName: "ChatChanges") }
      }
      .buttonStyle(.borderless)
      if item.isAnswerable {
        Button {
          answer(item, in: chat)
        } label: {
          Text("Answer Here", tableName: "ChatChanges")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  private func show(_ item: ChatTrayItem, in chat: UUID) {
    if let session, chat == session.session {
      session.focus(on: item.target)
    } else {
      chats.reveal(item.target, in: chat)
    }
  }

  /// Orchestrator decision 6: the chat opens on the message and answers it here; both replies stand.
  private func answer(_ item: ChatTrayItem, in chat: UUID) {
    show(item, in: chat)
    let model = chats.session(chat)
    Task {
      await model.refreshActivity()
      await model.answerHere()
    }
  }

  private func isHere(_ item: ChatTrayItem) -> Bool { session.map { item.session.id == $0.session } ?? false }

  private func openable(_ item: ChatTrayItem) -> UUID? {
    ChatTrayText.chat(of: item) { chats.overview(of: $0) != nil }
  }

  private func source(_ item: ChatTrayItem) -> String {
    ChatTrayText.source(of: item, here: session?.session, chats: chats)
  }
}

/// pending-items.ts:55-66 for a chat's cards, with the kinds the native tray adds.
enum ChatTrayText {
  @ViewBuilder
  static func chip(_ kind: ChatTrayItem.Kind) -> some View {
    switch kind {
    case .card(nil): ShadowBadge(Text("changes", tableName: "ChatChanges"), intent: .neutral)
    case .card: ShadowBadge(Text("conflict", tableName: "ChatChanges"), intent: .danger)
    case .unreadableCard: ShadowBadge(Text("changes", tableName: "ChatChanges"), intent: .warning)
    case .actions: ShadowBadge(Text("actions", tableName: "ChatChanges"), intent: .warning)
    case .question: ShadowBadge(Text("question", tableName: "ChatChanges"), intent: .accent)
    case .elsewhere, .interrupted, .failed: ShadowBadge(Text("message", tableName: "ChatChanges"), intent: .info)
    }
  }

  /// A chat the list holds; a deleted one, or one this device has not received, has no thread to show the item in.
  static func chat(of item: ChatTrayItem, listed: (UUID) -> Bool) -> UUID? {
    guard case .deleted = item.session else { return item.session.id.flatMap { listed($0) ? $0 : nil } }
    return nil
  }

  static func source(of item: ChatTrayItem, here: UUID?, chats: ChatNovelModel) -> String {
    switch item.session {
    case .none: return String(localized: "no chat", table: "ChatChanges")
    case .deleted: return String(localized: "a deleted chat", table: "ChatChanges")
    case .live(let id), .unknown(let id):
      if id == here { return String(localized: "this chat", table: "ChatChanges") }
      return chats.overview(of: id) == nil ? String(localized: "another chat", table: "ChatChanges") : chats.title(of: id)
    }
  }

  static func short(_ item: ChatTrayItem) -> String {
    switch item.kind {
    case .card(nil), .unreadableCard: String(localized: "chat changes", table: "ChatChanges")
    case .card: String(localized: "conflicted changes", table: "ChatChanges")
    case .actions: String(localized: "actions to run", table: "ChatChanges")
    case .question: String(localized: "question", table: "ChatChanges")
    case .elsewhere, .interrupted, .failed: String(localized: "unanswered message", table: "ChatChanges")
    }
  }

  static func title(_ item: ChatTrayItem) -> String {
    switch item.kind {
    case .unreadableCard: String(localized: "A card this version cannot read", table: "ChatChanges")
    case .elsewhere: String(localized: "Your message is being answered on another device", table: "ChatChanges")
    case .interrupted: String(localized: "A reply to your message was interrupted", table: "ChatChanges")
    case .failed: String(localized: "Your message didn't get a reply", table: "ChatChanges")
    case .card, .actions, .question: item.title ?? String(localized: "A card this version cannot read", table: "ChatChanges")
    }
  }

  /// The sweep's fault, under the detail as other errors show their code.
  static func code(_ kind: ChatTrayItem.Kind) -> String? {
    guard case .actions(_, .faulted(let code, _)) = kind else { return nil }
    return code
  }

  static func detail(_ kind: ChatTrayItem.Kind) -> String? {
    switch kind {
    case .card(let conflicts?):
      String(localized: "\(conflicts.count) changes no longer match your story. Apply what still fits, or discard the card.", table: "ChatChanges")
    case .actions(let indexes, .notHere):
      String(localized: "\(indexes.count) actions haven't finished on the device that applied this card.", table: "ChatChanges")
    case .actions(let indexes, .faulted(_, false)):
      String(localized: "\(indexes.count) actions stopped before they ran. Novel Forge tries them again the next time it opens.", table: "ChatChanges")
    case .actions(let indexes, .faulted(_, true)):
      String(localized: "\(indexes.count) actions stopped before they ran, and Novel Forge has stopped retrying them.", table: "ChatChanges")
    case .elsewhere(.folded?): String(localized: "It was folded into the chat's summary, so it can't be answered now.", table: "ChatChanges")
    case .elsewhere(.unrestricted?): String(localized: "It asks for unrestricted writing, which this version cannot do.", table: "ChatChanges")
    case .elsewhere(.unreadable?): String(localized: "This device can't read it, or a passage it points at.", table: "ChatChanges")
    case .card(nil), .unreadableCard, .question, .elsewhere(nil), .interrupted, .failed: nil
    }
  }
}

/// The transcript's copy for a waiting message it cannot answer, beside the chat's own unrestricted note.
enum ChatAnswerBlockText {
  static let folded = Text("It was folded into the chat's summary, so it can't be answered now. Send it again for a reply.", tableName: "ChatChanges")
  static let unreadable = Text("This device can't read it, or a passage it points at, so it can't be answered here.", tableName: "ChatChanges")
}

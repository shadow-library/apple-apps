import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct ChatSessionScreen: View {
  @Bindable var model: ChatSessionModel
  let chats: ChatNovelModel
  @Environment(AIServices.self) private var services

  var body: some View {
    ChatTranscriptFocus(model: model) { content }
      .background(ShadowColor.surfaceApp)
      .safeAreaInset(edge: .bottom, spacing: 0) { ChatBottomBar(model: model, chats: chats) }
      .chatCards(model)
      .task(id: model.generation) { await model.observe() }
      .aiConsentSheet($model.consentRequest, services: services, store: model.context.store) {
        Task { await model.consentAllowed() }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      ProgressView().fillingSurface()
    case .failed(let error):
      ShadowContentUnavailable(Text("This chat could not be read", tableName: "Chat"), kind: .error, message: error.text) {
        Button {
          model.retryReading()
        } label: {
          Text("Try Again", tableName: "Chat")
        }
      }
      .fillingSurface()
    case .loaded:
      if let page = model.page {
        transcript(page)
      } else {
        ChatUnavailable()
      }
    }
  }

  private func transcript(_ page: ChatTranscriptPage) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Spacing.space5) {
        if page.hasEarlier {
          Button {
            model.loadEarlier()
          } label: {
            Text("Show Earlier Messages", tableName: "Chat")
          }
          .buttonStyle(.borderless)
          .frame(maxWidth: .infinity)
        }
        if model.unreadableMessages > 0 {
          Text("\(model.unreadableMessages) messages cannot be read by this version", tableName: "Chat")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.warningText).frame(maxWidth: .infinity)
        }
        if page.messages.isEmpty && model.display == .idle {
          ChatHero(novelTitle: chats.novelTitle, mode: chats.mode(of: model.session))
            .frame(maxWidth: .infinity)
        }
        ForEach(page.messages, id: \.row.key) { message in
          ChatMessageRow(message: message, cost: message.record.flatMap { model.cost(of: $0.id) }) { reply in
            chats.presenting = .inspect(reply: reply)
          }
        }
        ChatTurnStatusView(model: model, mode: chats.mode(of: model.session))
        PlanStart(
          context: model.context, reveal: chats.waiting.planReveal, isBusy: model.isTurnActive || PlanStart.awaitsAnswer(model.messages))
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
  }
}

/// What sits under the transcript: what waits on the author across the novel, notices about this chat, then the composer.
struct ChatBottomBar: View {
  @Bindable var model: ChatSessionModel
  let chats: ChatNovelModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ChatWaitingTray(tray: chats.waiting, chats: chats, session: model)
      if chats.isArchived(model.session) {
        ShadowCallout(Text("This chat is archived.", tableName: "Chat"), intent: .info, systemImage: "archivebox") {
          Button {
            Task { await chats.setArchived(model.session, false) }
          } label: {
            Text("Unarchive", tableName: "Chat")
          }
        }
      }
      if let notice = model.notice {
        ShadowCallout(Text(verbatim: notice.error.headline), message: notice.error.detail.map { Text(verbatim: $0) }, intent: .warning) {
          if notice.opensSettings { AISettingsButton(store: model.context.store) }
        }
      }
      ChatComposer(
        state: model.composer, draft: $model.draft, sessionMode: chats.mode(of: model.session), offer: model.replyOffer, isOpening: false,
        canSend: model.canSendDraft && !chats.isArchived(model.session), isSending: model.isBusy, isLocked: chats.isArchived(model.session),
        isRunning: model.isTurnActive, saveMode: { [chats, session = model.session] mode in await chats.saveMode(mode, of: session) }
      ) {
        Task { await model.sendDraft() }
      } stop: {
        model.stop()
      }
    }
    .frame(maxWidth: 760)
    .frame(maxWidth: .infinity)
    .task(id: chats.waiting.generation) { await chats.waiting.observe() }
  }
}

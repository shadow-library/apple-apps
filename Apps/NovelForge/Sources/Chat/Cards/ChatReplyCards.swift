import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// ChatColumn.tsx:1236-1260: the reply's receipt, its card and its question, all in the thread since the native chat has no side panel.
struct ChatReplyCards: View {
  let reply: ChatMessageRecord
  let cards: ChatCardsContext

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      if let applied = reply.appliedProposal {
        ChatReceiptHost(proposal: applied, reply: reply, cards: cards).id(applied)
      }
      if let suggested = reply.cardProposal {
        ChatProposalCardHost(proposal: suggested, cards: cards).id(suggested)
      }
      question
    }
  }

  @ViewBuilder
  private var question: some View {
    if reply.question != nil {
      if let question = reply.questionCard, !question.answers.isEmpty {
        ChatQuestionHost(question: question, reply: reply, session: cards.session)
      } else {
        Label {
          Text("This reply asked a question this version cannot show.", tableName: "ChatCards")
        } icon: {
          Image(systemName: "questionmark.bubble")
        }
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

private struct ChatProposalCardHost: View {
  @State private var model: ChatProposalCardModel
  private let presenter: ChatCardsPresenter

  init(proposal: UUID, cards: ChatCardsContext) {
    presenter = cards.presenter
    _model = State(initialValue: ChatProposalCardModel(proposal: proposal, context: cards.context, writer: cards.writer))
  }

  var body: some View {
    ChatProposalCard(model: model, presenter: presenter)
  }
}

private struct ChatReceiptHost: View {
  @State private var model: ChatReceiptModel
  private let presenter: ChatCardsPresenter

  init(proposal: UUID, reply: ChatMessageRecord, cards: ChatCardsContext) {
    presenter = cards.presenter
    _model = State(initialValue: ChatReceiptModel(proposal: proposal, reply: reply, context: cards.context, writer: cards.writer))
  }

  var body: some View {
    ChatReceipt(model: model, presenter: presenter)
  }
}

/// ChatColumn.tsx:264 and :888: a question is settled once the author has written after it; answering waits while a turn runs.
private struct ChatQuestionHost: View {
  let question: ChatQuestion
  let reply: ChatMessageRecord
  let session: ChatSessionModel
  @State private var undecided: ChatCardNotice?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ChatQuestionCard(
        question: question, isSettled: ChatQuestionAnswering.isSettled(reply: reply.id, in: session.messages),
        isDisabled: session.isBusy || session.isTurnActive, answer: { await session.send($0) },
        leaveUndecided: { key in undecided = await ChatQuestionAnswering.leaveUndecided(key, session: session) })
      if let undecided {
        Text(verbatim: undecided.error.headline).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

@MainActor
enum ChatQuestionAnswering {
  static func isSettled(reply: UUID, in messages: [ChatTranscriptMessage]) -> Bool {
    guard let position = messages.first(where: { $0.record?.id == reply })?.position else { return false }
    return messages.contains { $0.position > position && $0.record?.role == .known(.user) }
  }

  /// ChatColumn.tsx:641-647: without a checklist item the chat is told; with one, the item is left open and counts as answered.
  static func leaveUndecided(_ key: ProgressItemKey?, session: ChatSessionModel) async -> ChatCardNotice? {
    guard let key else {
      await session.send(String(localized: "Undecided for now.", table: "ChatCards"))
      return nil
    }
    do throws(NotebookError) {
      try await NotebookService(store: session.context.store, novel: session.context.novel).override(key, as: .undecided)
      return ChatCardNotice(error: PresentedError(headline: String(localized: "Left open. It counts as answered on the checklist.", table: "ChatCards"), detail: nil))
    } catch {
      return ChatCardNotice(error: NotebookErrors.present(error))
    }
  }
}

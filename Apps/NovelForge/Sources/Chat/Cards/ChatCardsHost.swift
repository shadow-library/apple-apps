import Foundation
import NovelForgeCore
import Observation
import ShadowDesignSystem
import SwiftUI

/// What a reply's cards need from the chat around them, handed to a session's transcript through `\.chatCards`.
@MainActor
struct ChatCardsContext {
  let session: ChatSessionModel
  let writer: any ChatProposalWriting
  let presenter: ChatCardsPresenter

  var context: NovelContext { session.context }
}

extension EnvironmentValues {
  @Entry var chatCards: ChatCardsContext?
}

/// The transcript's one place for the cards' sheet and dialog, so a row the lazy stack recycles never takes an open one with it.
@MainActor
@Observable
final class ChatCardsPresenter {
  private(set) var revert: ChatRevertFlow?
  var discarding: ChatProposalCardModel?

  func present(_ flow: ChatRevertFlow) {
    guard flow.isPresented else { return }
    revert = flow
  }

  fileprivate var isRevertPresented: Bool {
    get { revert?.isPresented == true }
    set {
      guard !newValue else { return }
      revert?.cancel()
      if revert?.isPresented != true { revert = nil }
    }
  }

  fileprivate var isDiscardPresented: Bool {
    get { discarding != nil }
    set { if !newValue { discarding = nil } }
  }
}

private struct ChatCardsHost: ViewModifier {
  let session: ChatSessionModel
  @State private var presenter = ChatCardsPresenter()

  func body(content: Content) -> some View {
    @Bindable var presenter = presenter
    content
      .environment(\.chatCards, ChatCardsContext(session: session, writer: CoreChatProposalWriter(store: session.context.store), presenter: presenter))
      .sheet(isPresented: $presenter.isRevertPresented) {
        if let flow = presenter.revert { ChatRevertSheet(flow: flow) }
      }
      .confirmationDialog(Text("Discard these changes?", tableName: "ChatCards"), isPresented: $presenter.isDiscardPresented, titleVisibility: .visible) {
        Button(role: .destructive) {
          guard let card = presenter.discarding else { return }
          Task { await card.discard() }
        } label: {
          Text("Discard", tableName: "ChatCards")
        }
        .shadowDestructiveDialogAction()
      } message: {
        Text("Nothing on this card is applied. You can ask the chat again later.", tableName: "ChatCards")
      }
  }
}

extension View {
  /// Gives the session's replies their cards, with their sheet and dialog presented here rather than from a transcript row.
  func chatCards(_ session: ChatSessionModel) -> some View {
    modifier(ChatCardsHost(session: session))
  }
}

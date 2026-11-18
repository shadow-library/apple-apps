import NovelForgeCore
import SwiftUI

/// What the tray asks a transcript to show: a message, or the reply whose card or receipt carries a proposal (WaitingTray.tsx:114-122 marks the card).
nonisolated enum ChatFocusTarget: Equatable, Sendable {
  case message(UUID)
  case proposal(UUID)

  func matches(_ message: ChatTranscriptMessage) -> Bool {
    switch self {
    case .message(let id): message.record?.id == id
    case .proposal(let id): message.row.cardProposal == id || message.row.appliedProposal == id
    }
  }
}

/// Scrolls the transcript inside it to the row its session was asked to show, once the window holds that row.
struct ChatTranscriptFocus<Content: View>: View {
  let model: ChatSessionModel
  @ViewBuilder let content: Content

  var body: some View {
    ScrollViewReader { proxy in
      content.onChange(of: model.focusedRow, initial: true) { _, row in
        guard let row else { return }
        model.focusShown()
        Task { withAnimation { proxy.scrollTo(row, anchor: .center) } }
      }
    }
  }
}

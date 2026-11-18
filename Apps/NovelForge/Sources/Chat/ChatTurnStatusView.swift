import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// The transcript's last place: the turn running here, or how the last one ended (apps/novel-forge-web/src/features/chat/ChatColumn.tsx:900-922).
struct ChatTurnStatusView: View {
  let model: ChatSessionModel
  let mode: ChatSessionMode

  var body: some View {
    switch model.display {
    case .idle:
      EmptyView()
    case .running(let turn):
      StreamedTurnView(turn: turn, mode: mode, ending: .live)
    case .settling(let turn):
      StreamedTurnView(turn: turn, mode: mode, ending: .ended)
    case .stopped(let local, let turn):
      VStack(alignment: .leading, spacing: Spacing.space3) {
        StreamedTurnView(turn: turn, mode: mode, ending: .stopped(local.endedAt ?? local.updatedAt))
        if model.canRetry(local) { button(Text("Try Again", tableName: "Chat")) { await model.retry() } }
      }
    case .failed(let local, let failure, let turn):
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if turn.hasShownAnything { StreamedTurnView(turn: turn, mode: mode, ending: .ended) }
        ChatFailedTurn(failure: failure, store: model.context.store, canRetry: model.canRetry(local), isBusy: model.isBusy) { await model.retry() }
      }
    case .interrupted(_, let turn):
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if turn.hasShownAnything { StreamedTurnView(turn: turn, mode: mode, ending: .ended) }
        ShadowCallout(
          Text("This reply was interrupted", tableName: "Chat"),
          message: Text("It stopped when the app left the screen. Resume it from its last saved step.", tableName: "Chat"), intent: .info,
          systemImage: "pause.circle"
        ) {
          button(Text("Resume", tableName: "Chat")) { await model.resume() }
        }
      }
    case .elsewhere(let message, let answerable):
      ShadowCallout(
        Text("Being answered on another device", tableName: "Chat"), message: elsewhereMessage(model.answerBlock(message)), intent: .info,
        systemImage: "laptopcomputer.and.iphone"
      ) {
        if answerable { button(Text("Answer Here", tableName: "Chat")) { await model.answerHere() } }
      }
    }
  }

  private func elsewhereMessage(_ block: ChatAnswerBlock?) -> Text {
    switch block {
    case nil: Text("Its reply appears here when it arrives. Answer here to write a reply on this device as well; both stay in the chat.", tableName: "Chat")
    case .unrestricted: Text("It asks for unrestricted writing, which this version cannot do.", tableName: "Chat")
    case .folded: ChatAnswerBlockText.folded
    case .unreadable: ChatAnswerBlockText.unreadable
    }
  }

  private func button(_ title: Text, action: @escaping () async -> Void) -> some View {
    Button {
      Task { await action() }
    } label: {
      title
    }
    .disabled(model.isBusy)
  }
}

/// apps/novel-forge-web/src/components/nf/TurnStatus.tsx:115-137
struct ChatFailedTurn: View {
  let failure: TurnFailure
  let store: VaultStore
  let canRetry: Bool
  let isBusy: Bool
  let retry: () async -> Void

  var body: some View {
    let copy = ChatErrors.copy(for: failure)
    ShadowCallout(Text(verbatim: copy.title), message: message(copy), intent: .danger) {
      HStack(spacing: Spacing.space2) {
        if canRetry {
          Button {
            Task { await retry() }
          } label: {
            Text("Try Again", tableName: "Chat")
          }
          .disabled(isBusy)
        }
        if copy.opensSettings { AISettingsButton(store: store) }
      }
    }
  }

  private func message(_ copy: ChatFailureCopy) -> Text {
    let saved = String(localized: "Your message is saved.", table: "Chat")
    return PresentedError(headline: "\(copy.reason) \(saved)", detail: failure.code.isEmpty ? nil : failure.code).text
  }
}

/// A streamed turn as a timeline (apps/novel-forge-web/src/features/chat/StreamedTurn.tsx:23-35 over src/lib/chat-turn-timeline.ts:162-173): what was read,
/// the reply so far, what is being saved, and the live tail with its elapsed time.
struct StreamedTurnView: View {
  enum Ending: Equatable {
    case live
    case stopped(Date)
    case ended
  }

  let turn: StreamedTurn
  let mode: ChatSessionMode
  let ending: Ending

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ChatReadRow(lookups: turn.settledLookups(live: isLive))
      if !turn.text.isEmpty {
        ProseView(markdown: turn.text).opacity(isStopped ? 0.6 : 1)
      }
      if isLive && !turn.changes.isEmpty && turn.lastWrite != .change {
        Text(verbatim: ChatTurnTimeline.saving(turn.changes.count, mode: mode)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if isLive {
        TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in tail(at: context.date) }
      }
      if case .stopped(let end) = ending {
        Text(verbatim: ChatTurnTimeline.worked(end.timeIntervalSince(turn.startedAt), stopped: true, sources: turn.lookups.count { $0.status != .error }))
          .shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var isLive: Bool { ending == .live }

  private var isStopped: Bool {
    guard case .stopped = ending else { return false }
    return true
  }

  /// StreamedTurn's TurnLiveTail (TurnTimeline.tsx:100-121): the elapsed time from a second on, and a note once the turn turns slow.
  private func tail(at now: Date) -> some View {
    let elapsed = now.timeIntervalSince(turn.startedAt)
    return VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(spacing: Spacing.space2) {
        ProgressView().controlSize(.small)
        Text(verbatim: ChatTurnTimeline.tail(turn, mode: mode)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        if elapsed >= 1 {
          Text(verbatim: "· \(ChatTurnTimeline.elapsed(elapsed))").shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary).accessibilityHidden(true)
        }
      }
      if elapsed >= ChatTurnTimeline.slowAfter {
        Text(verbatim: ChatTurnTimeline.slowNote).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

/// TurnTimeline.tsx:26-90: what the turn read, as one line that opens on its sources.
struct ChatReadRow: View {
  let lookups: [StreamedLookup]

  var body: some View {
    if !lookups.isEmpty {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          ForEach(lookups) { lookup in
            Label {
              Text(verbatim: lookup.label)
            } icon: {
              Image(systemName: symbol(lookup.status))
            }
            .accessibilityValue(status(lookup.status))
          }
        }
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
      } label: {
        Text(verbatim: ChatTurnTimeline.readSummary(lookups)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func symbol(_ status: TurnLookupStatus) -> String {
    switch status {
    case .running: "circle.dotted"
    case .ok: "checkmark"
    case .error: "exclamationmark.triangle"
    }
  }

  // TurnTimeline.tsx:72
  private func status(_ status: TurnLookupStatus) -> Text {
    switch status {
    case .running: Text("reading", tableName: "Chat")
    case .ok: Text("read", tableName: "Chat")
    case .error: Text("couldn't be read", tableName: "Chat")
    }
  }
}

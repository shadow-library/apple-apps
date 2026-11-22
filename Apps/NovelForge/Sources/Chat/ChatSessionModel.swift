import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowAppShell
import ShadowStore

nonisolated struct ChatTranscriptSnapshot: Equatable, Sendable {
  let transcript: ChatTranscript
  let costs: [UUID: ChatReplyCost]

  static func load(_ query: ChatTranscriptQuery, in transaction: ReadTransaction) throws -> ChatTranscriptSnapshot {
    let transcript = try ChatTranscript.load(query, in: transaction)
    let costs = try transcript.page.value.map { try ChatReplyCosts.load($0.replyCalls, in: transaction).costs } ?? [:]
    return ChatTranscriptSnapshot(transcript: transcript, costs: costs)
  }
}

enum ChatTurnRequest: Equatable {
  case send(content: String, passages: [ChatTurnPassage], choices: ChatTurnChoices)
  case retry(turn: UUID)
  case resume(turn: UUID)
  case answer(message: UUID)
}

/// The session's turn as the transcript foot draws it.
enum ChatTurnDisplay: Equatable {
  case idle
  case running(StreamedTurn)
  /// Done, while the transcript has not caught up with its reply.
  case settling(StreamedTurn)
  case interrupted(LocalTurn, StreamedTurn)
  case stopped(LocalTurn, StreamedTurn)
  case failed(LocalTurn, TurnFailure, StreamedTurn)
  case elsewhere(message: UUID, answerable: Bool)
}

/// One chat: its transcript, newest at the bottom and paged back, and its turn on this device. A running turn is followed through the handle that started
/// it, or re-attached with `observe(turn:)` when the activity shows a turn this model is not following; a turn's end is read from its local turn, never
/// from its frames, since a turn failed at launch stores no error frame.
@MainActor
@Observable
final class ChatSessionModel {
  let session: UUID
  let context: NovelContext
  var draft = ""
  var consentRequest: AIConsentRequest?
  var notice: ChatNotice?
  /// What a message with no recorded mode follows: the novel's, standard unless known unrestricted (chat-selection.ts:22).
  var novelMode = ContentMode.standard
  var replyOffer = ChatReplyOffer.none
  @ObservationIgnored var turnEnded: (() -> Void)?
  let composer = ChatComposerState()
  private(set) var activity = ChatTurnActivity.idle
  private(set) var live: StreamedTurn?
  private(set) var isBusy = false
  private(set) var window = ChatTranscript.pageSize
  private(set) var generation = 0
  private(set) var focus: ChatFocusTarget?
  private let engine: ChatTurnEngine
  private let observer = ReadObserver<ChatTranscriptSnapshot>()
  @ObservationIgnored private var following: Task<Void, Never>?
  @ObservationIgnored private var awaitingConsent: ChatTurnRequest?
  @ObservationIgnored private var activityTicket = 0

  init(session: UUID, context: NovelContext, engine: ChatTurnEngine) {
    self.session = session
    self.context = context
    self.engine = engine
  }

  var state: Loadable<ChatTranscriptSnapshot> { observer.state }

  var page: ChatTranscriptPage? { state.value?.transcript.page.value }

  var messages: [ChatTranscriptMessage] { page?.messages ?? [] }

  var unreadableMessages: Int { (state.value?.transcript.state.value ?? nil)?.unreadableMessages ?? 0 }

  func cost(of reply: UUID) -> ChatReplyCost? { state.value?.costs[reply] }

  var display: ChatTurnDisplay {
    switch activity {
    case .running(let turn):
      let shown = streamed(turn)
      return shown.isFinished && shown.reply != nil ? .settling(shown) : .running(shown)
    case .interrupted(let turn):
      return .interrupted(turn, streamed(turn))
    case .ended(let turn) where turn.state == .cancelled:
      return .stopped(turn, streamed(turn))
    case .ended(let turn):
      return .failed(turn, turn.failure ?? TurnFailure(code: "", message: ""), streamed(turn))
    case .answeringElsewhere(let message):
      return .elsewhere(message: message, answerable: answerBlock(message) == nil)
    case .idle:
      guard let live else { return .idle }
      if !live.isFinished { return .running(live) }
      if let reply = live.reply, !messages.contains(where: { $0.record?.id == reply }) { return .settling(live) }
      return .idle
    }
  }

  var isTurnActive: Bool {
    switch display {
    case .running, .settling: true
    default: false
    }
  }

  /// ChatColumn.tsx:455-456: text, or comments alone, and never a comment on a passage that changed or while the mode is being saved.
  var canSendDraft: Bool {
    let hasWords = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.chips.isEmpty
    return !isBusy && !isTurnActive && hasWords && !composer.hasStaleChips && composer.switching == nil
  }

  /// Nil while the message is not in the window yet: the engine still refuses what it cannot answer.
  func answerBlock(_ message: UUID) -> ChatAnswerBlock? {
    messages.first { $0.record?.id == message }.flatMap { ChatAnswerBlock.of($0, novelMode: novelMode) }
  }

  var focusedRow: EntityKey? {
    guard let focus else { return nil }
    return messages.last(where: focus.matches)?.row.key
  }

  /// The window grows a page at a time until it holds the target.
  func focus(on target: ChatFocusTarget) {
    focus = target
    revealFocus()
  }

  func focusShown() {
    focus = nil
  }

  /// Retry asks again with the message as it was sent; one that asked for unrestricted writing waits for the flag.
  func canRetry(_ turn: LocalTurn) -> Bool {
    !asksForUnrestricted(turn.userMessage)
  }

  func observe() async {
    let (store, query) = (context.store, ChatTranscriptQuery(session: session, limit: window))
    await observer.run(
      { store.observeReads { transaction in try ChatTranscriptSnapshot.load(query, in: transaction) } },
      onValue: { [weak self] _ in self?.transcriptChanged() })
  }

  func retryReading() {
    generation += 1
  }

  /// chat-session.service.ts:116-129 reads the latest page before a position; the window grows instead, so earlier messages stay live.
  func loadEarlier() {
    window += ChatTranscript.pageSize
    generation += 1
  }

  func sendDraft() async {
    guard canSendDraft else { return }
    await send(draft.trimmingCharacters(in: .whitespacesAndNewlines), passages: composer.passages, choices: composer.choices(offer: replyOffer))
  }

  /// The composer's way in: `true` once the author's message is saved and its turn runs.
  @discardableResult
  func send(_ content: String, passages: [ChatTurnPassage] = [], choices: ChatTurnChoices = ChatTurnChoices()) async -> Bool {
    await perform(.send(content: content, passages: passages, choices: choices))
  }

  func stop() {
    guard case .running(let turn) = display else { return }
    engine.cancel(turn: turn.turn)
  }

  func retry() async {
    switch display {
    case .failed(let turn, _, _), .stopped(let turn, _): await perform(.retry(turn: turn.id))
    default: return
    }
  }

  func resume() async {
    guard case .interrupted(let turn, _) = display else { return }
    await perform(.resume(turn: turn.id))
  }

  /// Orchestrator decision 6: answers here a message another device is answering; both replies stand.
  func answerHere() async {
    guard case .elsewhere(let message, true) = display else { return }
    await perform(.answer(message: message))
  }

  func consentAllowed() async {
    guard let request = awaitingConsent else { return }
    awaitingConsent = nil
    await perform(request)
  }

  func refreshActivity() async {
    activityTicket += 1
    let ticket = activityTicket
    guard let next = try? await engine.activity(session: session), ticket == activityTicket else { return }
    activity = next
    attach(to: next)
  }

  @discardableResult
  private func perform(_ request: ChatTurnRequest) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    notice = nil
    defer { isBusy = false }
    do throws(ChatTurnError) {
      let handle = try await start(request)
      activityTicket += 1
      follow(handle.turn, from: Date()) { handle.events }
      if case .send(let content, let passages, _) = request {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == content { draft = "" }
        composer.sent(passages)
      }
      return true
    } catch .routing(.consentRequired(let consent)) {
      awaitingConsent = request
      consentRequest = consent
    } catch {
      if case .send(_, let passages, _) = request { await refused(error, passages: passages) }
      notice = ChatErrors.notice(error)
      await refreshActivity()
    }
    return false
  }

  /// ChatColumn.tsx:399-406, :449: a refusal names one chapter at most, so the sent passages are anchored again to tell which changed.
  private func refused(_ error: ChatTurnError, passages: [ChatTurnPassage]) async {
    composer.refused(error)
    guard case .passage(let code, _) = error, code == "CHT_009" else { return }
    let (store, novel) = (context.store, context.novel)
    let unresolved = try? await store.read { transaction in try ChatPassageSource.unresolved(passages, novel: novel, in: transaction) }
    composer.markStale(passages, unresolved: unresolved ?? [])
  }

  private func start(_ request: ChatTurnRequest) async throws(ChatTurnError) -> ChatTurnHandle {
    switch request {
    case .send(let content, let passages, let choices):
      try await engine.send(content, passages: passages, session: session, novel: context.novel, choices: choices)
    case .retry(let turn): try await engine.retry(turn: turn)
    case .resume(let turn): try await engine.resume(turn: turn)
    case .answer(let message): try await engine.answer(message: message, session: session, novel: context.novel)
    }
  }

  private func transcriptChanged() {
    revealFocus()
    Task { await refreshActivity() }
  }

  private func revealFocus() {
    guard focus != nil, focusedRow == nil, let page else { return }
    if page.hasEarlier { loadEarlier() } else { focus = nil }
  }

  private func attach(to activity: ChatTurnActivity) {
    switch activity {
    case .running(let turn), .interrupted(let turn), .ended(let turn):
      let stale = live?.turn == turn.id && activity.isRunning && live?.isFinished == true && live?.reply == nil && live?.failure == nil
      guard live?.turn != turn.id || stale else { return }
      let engine = engine
      follow(turn.id, from: turn.startedAt) {
        (try? await engine.observe(turn: turn.id)) ?? AsyncStream { $0.finish() }
      }
    case .idle, .answeringElsewhere:
      return
    }
  }

  private func follow(_ turn: UUID, from startedAt: Date, events: @escaping () async -> AsyncStream<TurnStreamEvent>) {
    following?.cancel()
    live = StreamedTurn(turn: turn, startedAt: startedAt)
    following = Task { [weak self] in
      for await event in await events() {
        guard let self else { return }
        self.receive(event, of: turn)
      }
      guard let self, !Task.isCancelled else { return }
      if live?.turn == turn { live?.finish() }
      turnEnded?()
      await refreshActivity()
    }
  }

  private func receive(_ event: TurnStreamEvent, of turn: UUID) {
    guard live?.turn == turn else { return }
    live?.apply(event)
  }

  private func streamed(_ turn: LocalTurn) -> StreamedTurn {
    guard let live, live.turn == turn.id else { return StreamedTurn(turn: turn.id, startedAt: turn.startedAt) }
    return live
  }

  private func asksForUnrestricted(_ message: UUID) -> Bool {
    guard !UnrestrictedWriting.isAvailable else { return false }
    guard let record = messages.first(where: { $0.record?.id == message })?.record else { return false }
    return (record.contentMode?.known ?? novelMode) == .unrestricted
  }
}

extension ChatTurnActivity {
  /// A turn resumed at launch keeps its id, so a chat that followed it to its interruption follows it again once it runs.
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }
}

import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

nonisolated struct ChatSessionsSnapshot: Equatable, Sendable {
  let all: ChatSessionList
  let active: ChatSessionList
  let archived: ChatSessionList
  let novel: NovelRecord?

  /// The open chat is resolved against every chat, unfiltered; History lists only chats the author posted in
  /// (apps/novel-forge-web/src/routes/novels/$novelId/chat.tsx:183-184, :362-364).
  static func load(novel: UUID, in transaction: ReadTransaction) throws -> ChatSessionsSnapshot {
    ChatSessionsSnapshot(
      all: try ChatSessionList.load(ChatSessionListQuery(novel: novel, filter: .all), in: transaction),
      active: try ChatSessionList.load(ChatSessionListQuery(novel: novel, filter: .active, startedOnly: true), in: transaction),
      archived: try ChatSessionList.load(ChatSessionListQuery(novel: novel, filter: .archived, startedOnly: true), in: transaction),
      novel: try NovelRecord.read(id: novel, in: transaction).entry?.record)
  }
}

enum ChatSheet: Identifiable, Equatable {
  case history
  case changes
  case inspect(reply: UUID)

  var id: String {
    switch self {
    case .history: "history"
    case .changes: "changes"
    case .inspect(let reply): "inspect-\(reply.uuidString)"
    }
  }
}

enum ChatChoice: Equatable {
  case latest
  case session(UUID)
  case draft
}

/// A novel's chats: which one is open, the opening composer before a chat exists, and the session operations. Kept per novel above the section switch,
/// with one model per chat, so a turn's live view and a typed message survive leaving the section.
@MainActor
@Observable
final class ChatNovelModel {
  let context: NovelContext
  var presenting: ChatSheet?
  var failure: ActionFailure?
  var draft = ""
  let composer = ChatComposerState()
  let waiting: ChatTrayModel
  var renaming: UUID?
  var renameText = ""
  var deleting: UUID?
  private(set) var choice = ChatChoice.latest
  private(set) var generation = 0
  private(set) var isStarting = false
  private let engine: ChatTurnEngine
  private let observer = ReadObserver<ChatSessionsSnapshot>()
  @ObservationIgnored var turnEnded: (() -> Void)? {
    didSet { for session in sessions.values { session.turnEnded = turnEnded } }
  }
  @ObservationIgnored private var sessions: [UUID: ChatSessionModel] = [:]
  @ObservationIgnored private var created: UUID?
  @ObservationIgnored private var startRequest = 0

  init(context: NovelContext, engine: ChatTurnEngine) {
    self.context = context
    self.engine = engine
    waiting = ChatTrayModel(context: context, engine: engine)
    waiting.live = { [weak self] session in self?.sessions[session]?.activity }
  }

  var state: Loadable<ChatSessionsSnapshot> { observer.state }

  var overviews: [ChatSessionOverview] { state.value?.all.sessions.value ?? [] }

  var current: UUID? { current(among: overviews) }

  var novelTitle: String? { state.value?.novel?.displayTitle }

  var replyOffer: ChatReplyOffer { ChatReplyOffer(novel: state.value?.novel) }

  func overview(of session: UUID) -> ChatSessionOverview? {
    overviews.first { $0.state.session == session }
  }

  func title(of session: UUID) -> String {
    overview(of: session)?.record?.displayTitle ?? String(localized: "New chat", table: "Chat")
  }

  func isArchived(_ session: UUID) -> Bool {
    overview(of: session)?.record?.status == .known(.archived)
  }

  func mode(of session: UUID) -> ChatSessionMode {
    overview(of: session)?.record?.mode.known ?? .auto
  }

  func session(_ id: UUID) -> ChatSessionModel {
    if let existing = sessions[id] { return existing }
    let model = ChatSessionModel(session: id, context: context, engine: engine)
    model.novelMode = novelMode
    model.turnEnded = turnEnded
    model.replyOffer = replyOffer
    sessions[id] = model
    return model
  }

  func refreshActivities() async {
    for model in sessions.values { await model.refreshActivity() }
    await waiting.refreshActivities()
  }

  func observe() async {
    let (store, novel) = (context.store, context.novel)
    await observer.run(
      { store.observeReads { transaction in try ChatSessionsSnapshot.load(novel: novel, in: transaction) } },
      onValue: { [weak self] snapshot in self?.forgetRemoved(snapshot) })
  }

  func retry() {
    generation += 1
  }

  func open(_ session: UUID) {
    choice = .session(session)
  }

  /// Opens the chat and has its transcript show the target; another section reaches it through this and `navigator.show(.chat)`.
  func reveal(_ target: ChatFocusTarget, in session: UUID) {
    open(session)
    self.session(session).focus(on: target)
  }

  /// chat.tsx:415-421: the chat that does not exist yet, created by its first message. A create still in flight is abandoned: it opens nothing.
  func newChat() {
    startRequest += 1
    isStarting = false
    choice = .draft
    composer.startOver()
  }

  /// ChatColumn.tsx:461-465: the opening message needs words of its own; comments go with it.
  var canStartDraft: Bool {
    !isStarting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !composer.hasStaleChips
  }

  func startDraft() async {
    guard canStartDraft else { return }
    await startChat(draft, passages: composer.passages, choices: composer.choices(offer: replyOffer))
  }

  /// A Reader comment joins the open chat's composer, else the opening one; the chats are read once if they have not been yet.
  func addPassage(_ chip: ChatPassageChip) async -> ChatPassageAddition {
    var listed = state.value?.all.sessions.value
    if listed == nil {
      let (store, novel) = (context.store, context.novel)
      listed = try? await store.read { transaction in try ChatSessionsSnapshot.load(novel: novel, in: transaction) }.all.sessions.value
    }
    guard let open = current(among: listed ?? []) else { return composer.add(chip) }
    return session(open).composer.add(chip)
  }

  /// chat.tsx:424-443: the opening message creates the chat, then goes out through that chat's own sending path, carrying the composer's text with it so
  /// a refusal or a consent prompt leaves it there.
  @discardableResult
  func startChat(_ content: String, passages: [ChatTurnPassage] = [], choices: ChatTurnChoices = ChatTurnChoices()) async -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !passages.isEmpty, !isStarting else { return false }
    startRequest += 1
    let request = startRequest
    isStarting = true
    defer { if request == startRequest { isStarting = false } }
    let record: ChatSessionRecord
    do {
      record = try await context.store.createChatSession(novel: context.novel, mode: composer.draftMode)
    } catch {
      if request == startRequest { failure = ActionFailure(error: ChatErrors.presented(error)) }
      return false
    }
    guard request == startRequest else { return false }
    created = record.id
    choice = .session(record.id)
    let opened = session(record.id)
    if draft.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
      opened.draft = draft
      draft = ""
      opened.composer.adopt(composer)
    }
    return await opened.send(trimmed, passages: passages, choices: choices)
  }

  func beginRename(_ session: UUID) {
    renameText = overview(of: session)?.record?.title ?? ""
    renaming = session
  }

  /// A blank title clears the author's name and leaves the automatic one.
  func commitRename() async {
    guard let session = renaming else { return }
    renaming = nil
    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    await attempt { () async throws(ChatSessionError) in
      try await self.context.store.renameChatSession(session, novel: self.context.novel, title: trimmed.isEmpty ? nil : trimmed)
    }
  }

  func setArchived(_ session: UUID, _ archived: Bool) async {
    let (store, novel) = (context.store, context.novel)
    await attempt { () async throws(ChatSessionError) in
      if archived {
        try await store.archiveChatSession(session, novel: novel)
      } else {
        try await store.unarchiveChatSession(session, novel: novel)
      }
    }
  }

  /// chat.tsx:447-451: deleting the open chat drops the author into the newest active one, or the opening composer.
  func confirmDelete() async {
    guard let session = deleting else { return }
    deleting = nil
    let (store, novel) = (context.store, context.novel)
    let deleted = await attempt { () async throws(ChatSessionError) in try await store.deleteChatSession(session, novel: novel) }
    guard deleted, choice == .session(session) else { return }
    choice = .latest
  }

  @discardableResult
  private func attempt(_ body: () async throws(ChatSessionError) -> Void) async -> Bool {
    do {
      try await body()
      return true
    } catch {
      failure = ActionFailure(error: ChatErrors.presented(error))
      return false
    }
  }

  private func forgetRemoved(_ snapshot: ChatSessionsSnapshot) {
    guard let listed = snapshot.all.sessions.value.map({ Set($0.map(\.state.session)) }) else { return }
    if let created, listed.contains(created) { self.created = nil }
    sessions = sessions.filter { listed.contains($0.key) || $0.key == created }
    for model in sessions.values {
      model.novelMode = novelMode
      model.replyOffer = replyOffer
    }
  }

  /// chat.tsx:398-404: the chat asked for while it is still there, else the most recently updated active one; New chat asks for none.
  private func current(among overviews: [ChatSessionOverview]) -> UUID? {
    switch choice {
    case .draft: return nil
    case .session(let id) where id == created || overviews.contains(where: { $0.state.session == id }): return id
    case .session, .latest: return overviews.first { $0.record?.status == .known(.active) }?.state.session
    }
  }

  private var novelMode: ContentMode { state.value?.novel?.contentMode.known == .unrestricted ? .unrestricted : .standard }
}

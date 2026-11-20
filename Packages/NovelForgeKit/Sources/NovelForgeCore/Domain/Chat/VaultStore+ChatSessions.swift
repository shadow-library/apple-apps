import Foundation
import ShadowAI
import ShadowStore

extension VaultStore {
  /// A new, untitled chat of the novel (chat-session.service.ts:52-61).
  @discardableResult
  public func createChatSession(novel: UUID, mode: ChatSessionMode = .auto) async throws(ChatSessionError) -> ChatSessionRecord {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.create(novel: novel, mode: mode, in: &transaction) }
  }

  /// The author's title; nil clears it, leaving the automatic name.
  public func renameChatSession(_ session: UUID, novel: UUID, title: String?) async throws(ChatSessionError) {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.rename(session, novel: novel, title: title, in: &transaction) }
  }

  public func setChatSessionMode(_ session: UUID, novel: UUID, mode: ChatSessionMode) async throws(ChatSessionError) {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.setMode(session, novel: novel, mode: mode, in: &transaction) }
  }

  public func archiveChatSession(_ session: UUID, novel: UUID) async throws(ChatSessionError) {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.setStatus(session, novel: novel, status: .archived, in: &transaction) }
  }

  public func unarchiveChatSession(_ session: UUID, novel: UUID) async throws(ChatSessionError) {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.setStatus(session, novel: novel, status: .active, in: &transaction) }
  }

  /// Removes the chat and clears what this device kept of its turns; its cards stay in the change history.
  public func deleteChatSession(_ session: UUID, novel: UUID) async throws(ChatSessionError) {
    try await writeChat { transaction throws(ChatSessionError) in try ChatSessionOperations.delete(session, novel: novel, in: &transaction) }
  }

  /// Clears everything this device keeps of the novel beside the vault: its chats' turns and replayed exchanges, its writer Inspector rows and pinned packs,
  /// and its retrieval index. The novel's deletion, which a later phase brings, calls it.
  public func forgetLocalState(novel: UUID) async throws(StoreError) {
    try await write { transaction in try ChatLocalCleanup.forget(novel: novel, in: transaction.database) }
  }

  /// Clears this device's turns and replayed exchanges of the chats deleted elsewhere; the turn engine calls it at launch, before resuming turns.
  @discardableResult
  func forgetRemovedLocalChats() async throws(StoreError) -> [UUID] {
    try await write { transaction in try ChatLocalCleanup.forgetRemovedSessions(in: transaction.database) }
  }

  /// Names the session from its opening author message when it has no title yet; the turn engine runs it beside the turn.
  func nameChatSession(_ session: UUID, novel: UUID, opening message: UUID, turn: ChatAutoTitleTurn, router: TaskRouter) async throws(ChatAutoTitleError)
    -> ChatAutoTitleOutcome
  {
    try await ChatAutoTitle.name(session: session, novel: novel, opening: message, turn: turn, store: self, router: router)
  }

  private func writeChat<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(ChatSessionError) -> T) async throws(ChatSessionError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let chat = cause as? ChatSessionError { throw chat }
      throw .store(error)
    }
  }
}

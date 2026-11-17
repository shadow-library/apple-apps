import Foundation
import ShadowAI
import ShadowStore

/// The turn whose opening message names its session, in the shape `VaultStore.nameChatSession` takes as `ChatAutoTitleTurn`.
struct ChatTitleTurn: Equatable, Sendable {
  let pace: Pace
  let contentMode: ContentMode
  let consent: AIConsentRequirement
}

/// The session upkeep a turn relies on: naming a session from its opening message beside the turn (chat.service.ts:331), which answers the ledger ids the
/// naming spent, and clearing this device's turns of chats deleted elsewhere before launch resumes any.
struct ChatSessionUpkeep: Sendable {
  let nameSession: @Sendable (_ session: UUID, _ novel: UUID, _ opening: UUID, _ turn: ChatTitleTurn, _ router: TaskRouter) async -> [UUID]
  let forgetRemovedChats: @Sendable () async throws(StoreError) -> Void
}

extension ChatSessionUpkeep {
  /// The session operations of `Domain/Chat`: a naming that fails still reports the ledger ids it spent.
  static func vault(_ store: VaultStore) -> ChatSessionUpkeep {
    ChatSessionUpkeep(
      nameSession: { session, novel, opening, turn, router in
        let named = ChatAutoTitleTurn(pace: turn.pace, contentMode: turn.contentMode, consent: turn.consent)
        do throws(ChatAutoTitleError) {
          switch try await store.nameChatSession(session, novel: novel, opening: opening, turn: named, router: router) {
          case .named(_, let calls), .kept(let calls), .refused(_, let calls): return calls
          case .skipped: return []
          }
        } catch {
          if case .model(_, let calls) = error { return calls }
          return []
        }
      },
      forgetRemovedChats: { () throws(StoreError) in _ = try await store.forgetRemovedLocalChats() })
  }
}

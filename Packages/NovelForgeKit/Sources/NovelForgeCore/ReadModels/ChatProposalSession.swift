import Foundation
import GRDB
import ShadowStore

/// The chat a card was staged in, as this device can tell: a deleted chat's cards stay, detached, as the reference's do (chat-session.service.ts:109).
public enum ChatProposalSession: Sendable, Equatable {
  case none
  case live(UUID)
  case deleted(UUID)
  /// The chats' derived state is faulted here, so whether this chat was deleted is not known.
  case unknown(UUID)

  public var id: UUID? {
    switch self {
    case .none: nil
    case .live(let id), .deleted(let id), .unknown(let id): id
    }
  }
}

/// Which of the novel's chats were deleted, read so that a fault on the chats' derived state makes only the session unknown, never the cards unavailable.
struct ChatSessionStandings {
  private let removed: Set<UUID>
  private let unknownAll: Bool
  private let unknownKeys: Set<String>

  init(novel: UUID, in transaction: ReadTransaction) throws(StoreError) {
    let table = ChatSessionState.databaseTableName
    let upstream = DerivedDependencies.closure(of: [table])
    let faults = try FaultRows(in: transaction).rows.map { (derivation: $0["derivation"] as String, key: $0["key"] as String) }
    unknownAll = faults.contains { upstream.contains($0.derivation) && $0.key == ProjectionFaults.wholeDerivation }
    unknownKeys = Set(faults.filter { $0.derivation == table && $0.key != ProjectionFaults.wholeDerivation }.map(\.key))
    removed = try transaction.query { database in
      Set(try UUID.fetchAll(database, sql: "SELECT session FROM \(table) WHERE novel = ? AND record = ?", arguments: [novel, ChatSessionRecordState.removed]))
    }
  }

  func standing(of session: UUID?) -> ChatProposalSession {
    guard let session else { return .none }
    if unknownAll || unknownKeys.contains(ProjectionFaults.key(NovelForgeKey.chatSession(session))) { return .unknown(session) }
    return removed.contains(session) ? .deleted(session) : .live(session)
  }
}

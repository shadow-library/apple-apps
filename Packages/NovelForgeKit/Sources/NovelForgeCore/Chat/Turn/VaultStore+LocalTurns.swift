import Foundation
import ShadowStore

extension VaultStore {
  /// The session's running or ended turn on this device; `lastMessage` is the newest message of its transcript. A session whose transcript ends on an
  /// unanswered message and that has no turn here is being answered on another device, or was by a database this one was restored or cloned from.
  public func localTurnStatus(session: UUID, lastMessage: UUID?) async throws(StoreError) -> LocalTurnStatus {
    let replica = replica
    return try await read { transaction in
      try LocalTurnStore.status(session: session, lastMessage: lastMessage, replica: replica, in: transaction.database)
    }
  }

  /// The pending turns this replica began, oldest first; after a restart these are the interrupted ones.
  public func pendingLocalTurns() async throws(StoreError) -> [LocalTurn] {
    let replica = replica
    return try await read { transaction in try LocalTurnStore.pending(replica: replica, in: transaction.database) }
  }

  public func localTurn(_ id: UUID) async throws(StoreError) -> LocalTurn? {
    try await read { transaction in try LocalTurnStore.turn(id, in: transaction.database) }
  }

  /// The turn's stored frames after `sequence`, for a resumed view or the Inspector.
  public func localTurnFrames(_ turn: UUID, after sequence: Int = 0) async throws(StoreError) -> [TurnFrame] {
    try await read { transaction in try LocalTurnStore.frames(of: turn, after: sequence, in: transaction.database) }
  }

  /// Dismisses an ended turn, or abandons one that will not be resumed.
  public func clearLocalTurn(_ turn: UUID) async throws(StoreError) {
    try await write { transaction in try LocalTurnStore.finish(turn, in: transaction.database) }
  }

  @discardableResult
  func appendLocalTurnFrames(_ frames: [TurnFrame], turn: UUID, at now: Date = Date()) async throws(StoreError) -> Bool {
    try await write { transaction in try LocalTurnStore.append(frames, turn: turn, at: now, in: transaction.database) }
  }

  @discardableResult
  func saveLocalTurnRound(_ checkpoint: LocalTurnCheckpoint, turn: UUID, at now: Date = Date()) async throws(StoreError) -> Bool {
    try await write { transaction in try LocalTurnStore.save(checkpoint, turn: turn, at: now, in: transaction.database) }
  }

  /// Fails every pending turn of this replica outside `resumed`; called at launch once the turns to resume are chosen, so none shows as running for ever.
  @discardableResult
  func failStaleLocalTurns(except resumed: Set<UUID>, at now: Date = Date()) async throws(StoreError) -> [UUID] {
    let replica = replica
    return try await write { transaction in try LocalTurnStore.failStale(replica: replica, except: resumed, at: now, in: transaction.database) }
  }

  /// Ends the turn and stores its last frames in one write, so a stored end always follows the frames before it.
  @discardableResult
  func endLocalTurn(_ turn: UUID, as end: LocalTurnEnd, frames: [TurnFrame] = [], at now: Date = Date()) async throws(StoreError) -> Bool {
    try await write { transaction in
      try LocalTurnStore.append(frames, turn: turn, at: now, in: transaction.database)
      return try LocalTurnStore.end(turn, as: end, at: now, in: transaction.database)
    }
  }
}

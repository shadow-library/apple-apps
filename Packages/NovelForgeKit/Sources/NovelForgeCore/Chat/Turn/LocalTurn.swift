import Foundation
import ShadowCore

/// `cancelled` is the author stopping the turn deliberately: terminal, not a failure, and never retried automatically
/// (apps/novel-forge-server/src/modules/refinement/chat.service.ts:82-90).
public enum LocalTurnState: String, Sendable, CaseIterable {
  case pending
  case failed
  case cancelled
}

/// How a turn that never appended its reply ended.
enum LocalTurnEnd: Sendable, Equatable {
  case failed(TurnFailure)
  case cancelled
}

/// What a turn has gathered by the end of a lookup round, so a resumed turn on this device asks the model again from there instead of from the start
/// (orchestrator decision 6). `messages` are every message the rounds so far added to the request, in order; `carry` is what the turn engine keeps across
/// rounds (lookup counts, the planner flag, the trace) in its own encoding.
struct LocalTurnCheckpoint: Equatable, Sendable {
  let round: Int
  let messages: [PromptMessage]
  let carry: JSONValue
}

/// A chat turn this device started and has not finished: one row from the moment the author's message is saved until the reply is appended, kept on this
/// device only. A turn that failed or was cancelled stays until the session's next turn begins or it is cleared.
public struct LocalTurn: Sendable, Equatable {
  public let id: UUID
  public let novel: UUID
  public let session: UUID
  public let userMessage: UUID
  /// The replica that began it; a database restored or cloned onto another device carries a different one and must not resume it.
  public let replica: ReplicaID
  public let state: LocalTurnState
  public let startedAt: Date
  /// When a frame, a round or the end was last saved.
  public let updatedAt: Date
  public let endedAt: Date?
  /// Nil while pending and for a cancelled turn.
  public let failure: TurnFailure?
  /// The highest frame sequence stored, 0 when none; a resumed turn's log numbers on from it.
  public let lastSequence: Int
  /// Nil when no round was saved or the saved one cannot be read; the turn then resumes from the start, which only repeats read-only lookups.
  let checkpoint: LocalTurnCheckpoint?
  /// The author stopped it while it ran here and its end was not written: a launch ends it cancelled, unless its answer had settled.
  let stopped: Bool

  /// Lookup rounds a resume can skip.
  public var savedRounds: Int { checkpoint?.round ?? 0 }
}

/// The session's turn as the transcript shows it (chat.service.ts:223-230): the pending turn when one runs; otherwise the turn that failed or was cancelled,
/// only while the transcript still ends on its message.
public struct LocalTurnStatus: Sendable, Equatable {
  public let pending: LocalTurn?
  public let ended: LocalTurn?

  public static let idle = LocalTurnStatus(pending: nil, ended: nil)
}

import Foundation
import ShadowText

// apps/novel-forge-server/src/modules/refinement/turn-stream.types.ts:2
public enum TurnStreamEventName: String, Sendable, CaseIterable {
  case user
  case lookup
  case delta
  case change
  case reset
  case done
  case error

  // turn-stream.types.ts:22
  public var isTerminal: Bool { self == .done || self == .error }
}

/// What a turn shows while it runs. `delta` and `change` belong to the reply being written and `reset` voids both; all are provisional, and `done` alone says
/// what the turn applied and carded (turn-stream.types.ts:1).
public enum TurnStreamEvent: Sendable, Equatable {
  /// The author's message, saved before the model is called.
  case user(message: UUID)
  case lookup(TurnLookupEvent)
  /// Never empty.
  case delta(String)
  case change(TurnChangeEvent)
  case reset
  /// The reply, appended with everything the turn applied and carded.
  case done(reply: UUID)
  case error(TurnFailure)

  public var name: TurnStreamEventName {
    switch self {
    case .user: .user
    case .lookup: .lookup
    case .delta: .delta
    case .change: .change
    case .reset: .reset
    case .done: .done
    case .error: .error
    }
  }
}

// apps/novel-forge-server/src/modules/refinement/chat-turn-emitter.ts:10
public enum TurnLookupStatus: String, Sendable {
  case running
  case ok
  case error
}

// chat-turn-emitter.ts:6
public struct TurnLookupEvent: Sendable, Equatable {
  public let round: Int
  public let tool: String
  let args: OrderedJSONObject
  public let status: TurnLookupStatus

  init(round: Int, tool: String, args: OrderedJSONObject, status: TurnLookupStatus) {
    self.round = round
    self.tool = tool
    self.args = args
    self.status = status
  }

  /// The arguments the model sent, as JSON text in their JavaScript key order.
  public var argumentsJSON: String { OrderedJSON.object(args).jsonText }
}

/// Where a change sits in the Story Bible progress list: people are characters and factions, threads are promises (chat-turn-emitter.ts:13).
public enum TurnChangeGroup: String, Sendable, CaseIterable {
  case premise
  case pages
  case people
  case places
  case power
  case threads
  case other
}

/// One change of the reply being written, display-only and provisional: `done` decides what applied or carded, `reset` voids earlier changes and restarts
/// `index` at 0 (chat-turn-emitter.ts:16).
public struct TurnChangeEvent: Sendable, Equatable {
  public let index: Int
  public let op: String
  public let label: String
  public let group: TurnChangeGroup

  public init(index: Int, op: String, label: String, group: TurnChangeGroup) {
    self.index = index
    self.op = op
    self.label = label
    self.group = group
  }
}

/// Why a turn ended without a reply; the reference sends the application error's code and message (turn-stream.service.ts:96).
public struct TurnFailure: Sendable, Equatable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

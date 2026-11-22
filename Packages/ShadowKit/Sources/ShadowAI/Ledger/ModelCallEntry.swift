import Foundation

public enum LedgerCostSource: String, Sendable, Codable, Comparable {
  case pending
  case computed
  case reported

  private var rank: Int {
    switch self {
    case .pending: 0
    case .computed: 1
    case .reported: 2
    }
  }

  public static func < (lhs: LedgerCostSource, rhs: LedgerCostSource) -> Bool {
    lhs.rank < rhs.rank
  }
}

public enum LedgerOutcome: String, Sendable, Codable {
  case started
  case failed
  case cancelled
  case finished

  static let order = [LedgerOutcome.started, .failed, .cancelled, .finished].map(\.rawValue)
}

public struct ModelCallEntry: Sendable, Equatable {
  public let id: UUID
  public let provider: String
  public let model: String
  public let task: ModelTask
  public let pace: Pace?
  public let startedMillis: Int64
  public let parent: UUID?
  public let requestID: String?
  public let generationID: String?
  public let outcome: LedgerOutcome
  public let usage: TokenUsage
  public let cost: Cost?
  public let costSource: LedgerCostSource

  public init(
    id: UUID,
    provider: String,
    model: String,
    task: ModelTask,
    pace: Pace?,
    startedMillis: Int64,
    parent: UUID? = nil,
    requestID: String? = nil,
    generationID: String? = nil,
    outcome: LedgerOutcome = .started,
    usage: TokenUsage = .zero,
    cost: Cost? = nil,
    costSource: LedgerCostSource = .pending
  ) {
    self.id = id
    self.provider = provider
    self.model = model
    self.task = task
    self.pace = pace
    self.startedMillis = startedMillis
    self.parent = parent
    self.requestID = requestID
    self.generationID = generationID
    self.outcome = outcome
    self.usage = usage
    self.cost = cost
    self.costSource = costSource
  }

  /// A call `DemoModelProvider` answered on the device, which cost nothing.
  public var isDemo: Bool { provider == DemoModelProvider.host }
}

public struct ModelCallStart: Sendable, Equatable {
  public let id: UUID
  public let provider: String
  public let model: String
  public let task: ModelTask
  public let pace: Pace?
  public let startedMillis: Int64

  public init(id: UUID, provider: String, model: String, task: ModelTask, pace: Pace?, startedMillis: Int64) {
    self.id = id
    self.provider = provider
    self.model = model
    self.task = task
    self.pace = pace
    self.startedMillis = startedMillis
  }
}

import Foundation
import ShadowCore

public enum ModelRequestScreening: Sendable {
  case allow
  case refuse(any ShadowError & Equatable)
}

/// A route's screen of every request it sends, repair re-asks and fallbacks included, before the provider or the ledger sees it. A refused request costs
/// nothing and writes no ledger row; the reference's telemetry writes a `refused` row instead (novel-forge-server/src/modules/ai/telemetry.handler.ts:131).
public struct ModelRequestGuard: Sendable {
  /// Sent as the first system segment of every allowed request, after the screen (synapse-request.ts:75-79).
  public let systemLine: String?
  public let screen: @Sendable (ModelRequest) -> ModelRequestScreening

  public init(systemLine: String? = nil, screen: @escaping @Sendable (ModelRequest) -> ModelRequestScreening) {
    self.systemLine = systemLine
    self.screen = screen
  }

  /// The request as sent once the screen allows it.
  public func framing(_ request: ModelRequest) -> ModelRequest {
    guard let systemLine, request.system.first?.text != systemLine else { return request }
    var framed = request
    framed.system.insert(ContextSegment(text: systemLine), at: 0)
    return framed
  }
}

public struct ModelRequestRefusal: ShadowError, Equatable {
  public let reason: any ShadowError & Equatable

  public init(_ reason: any ShadowError & Equatable) {
    self.reason = reason
  }

  public var code: String { reason.code }

  public var errorDescription: String? { reason.errorDescription }

  public static func == (lhs: ModelRequestRefusal, rhs: ModelRequestRefusal) -> Bool {
    lhs.reason.isEqual(to: rhs.reason)
  }
}

extension Equatable {
  fileprivate func isEqual(to other: any Equatable) -> Bool {
    (other as? Self) == self
  }
}

import Foundation
import ShadowCore

public struct LeaseInstant: Sendable, Hashable {
  public let millis: Int64
  public let source: AttemptClockSource

  public init(millis: Int64, source: AttemptClockSource) {
    self.millis = millis
    self.source = source
  }

  public init(date: Date, source: AttemptClockSource) {
    self.init(millis: Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0, source: source)
  }

  public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

  func adding(_ duration: Duration) -> LeaseInstant {
    LeaseInstant(millis: millis + duration.millis, source: source)
  }
}

public enum LeaseTerms {
  public static let duration: Duration = .seconds(360)
  public static let heartbeat: Duration = .seconds(120)
  /// The clock check's tolerance (plan, Clocks): a lease running out further ahead than a fresh one plus this was stamped by a clock too far ahead to trust.
  public static let skew: Duration = .seconds(300)
}

/// Trusted time when there is an estimate, else the device clock with its source recorded (orchestrator decision 10); a restored lower bound only lifts a
/// device clock that reads earlier than it.
public struct LeaseClock: Sendable {
  private let trusted: TrustedClock?
  private let device: @Sendable () -> Date

  public init(trusted: TrustedClock?, device: @escaping @Sendable () -> Date = { Date() }) {
    self.trusted = trusted
    self.device = device
  }

  public func now() -> LeaseInstant {
    let device = device()
    switch trusted?.now() ?? .unavailable {
    case .estimate(let estimate): return LeaseInstant(date: estimate, source: .trusted)
    case .lowerBound(let bound): return LeaseInstant(date: max(bound, device), source: .device)
    case .unavailable: return LeaseInstant(date: device, source: .device)
    }
  }
}

extension AttemptLease {
  public static func granted(at instant: LeaseInstant) -> AttemptLease {
    AttemptLease(expires: instant.adding(LeaseTerms.duration).millis, renewed: instant.millis, clock: instant.source)
  }

  public func isLive(at now: LeaseInstant) -> Bool {
    Self.isLive(expires: expires, at: now)
  }

  /// The one liveness rule, for readers that keep only a lease's expiry.
  public static func isLive(expires: Int64, at now: LeaseInstant) -> Bool {
    now.millis < expires && expires - now.millis <= (LeaseTerms.duration + LeaseTerms.skew).millis
  }
}

extension Duration {
  var millis: Int64 {
    let parts = components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
}

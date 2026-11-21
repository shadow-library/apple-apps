import Foundation

public struct SyncSchedulePolicy: Sendable, Equatable {
  /// Quiet time after the last local write before it is uploaded.
  public var uploadDelay: Duration
  public var pollInterval: Duration
  /// How often a device waiting for the vault's key looks for it while in front.
  public var keyCheckInterval: Duration
  public var firstRetryDelay: Duration
  public var maximumRetryDelay: Duration
  /// The longest wait a storage provider's retry-after is honoured with.
  public var maximumRetryAfter: Duration
  /// Consecutive failed attempts to reach storage before the status asks for attention.
  public var unreachableAfterFailures: Int
  public var maintenanceInterval: Duration

  public init(
    uploadDelay: Duration = .seconds(2),
    pollInterval: Duration = .seconds(45),
    keyCheckInterval: Duration = .seconds(30),
    firstRetryDelay: Duration = .seconds(2),
    maximumRetryDelay: Duration = .seconds(5 * 60),
    maximumRetryAfter: Duration = .seconds(60 * 60),
    unreachableAfterFailures: Int = 3,
    maintenanceInterval: Duration = .seconds(60 * 60)
  ) {
    self.uploadDelay = uploadDelay
    self.pollInterval = pollInterval
    self.keyCheckInterval = keyCheckInterval
    self.firstRetryDelay = firstRetryDelay
    self.maximumRetryDelay = maximumRetryDelay
    self.maximumRetryAfter = maximumRetryAfter
    self.unreachableAfterFailures = unreachableAfterFailures
    self.maintenanceInterval = maintenanceInterval
  }

  public func retryDelay(afterFailures failures: Int) -> Duration {
    guard failures > 0 else { return .zero }
    var delay = firstRetryDelay
    var doublings = failures - 1
    while doublings > 0, delay < maximumRetryDelay {
      delay *= 2
      doublings -= 1
    }
    return min(delay, maximumRetryDelay)
  }

  func honoured(retryAfter: Duration) -> Duration {
    min(max(retryAfter, .zero), maximumRetryAfter)
  }
}

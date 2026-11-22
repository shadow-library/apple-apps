import Foundation

/// How a runtime's runs have gone since it started, for a diagnostics report: counts, instants and error codes, never a location, key or record.
/// A run succeeds when it ends without a failure to retry, which includes a run that found nothing to sync or that stopped at a phase such as a locked
/// device; only a failed run records a code, the code of the error that failed it.
public struct SyncRunRecord: Sendable, Equatable {
  public var runs = 0
  public var failedRuns = 0
  public var consecutiveFailures = 0
  /// Local writes handed to the runtime that no upload has covered yet.
  public var unsentWrites = 0
  public var lastSucceeded: Date?
  public var lastFailed: Date?
  public var lastFailureCode: String?

  public init() {}
}

import CloudKit
import Foundation
import ShadowSync

/// How CloudKit failures reach the provider. Pure, so the table is tested from `CKError(code)` values.
public enum CloudKitErrorMap {
  public static func zoneError(_ error: any Error) -> CloudKitZoneError {
    switch error {
    case let error as CloudKitZoneError: error
    case let error as CKError: zoneError(error)
    case is CancellationError: .storage(cancelled)
    default: .storage(.underlying("CloudKit failed: \((error as NSError).domain) \((error as NSError).code)"))
    }
  }

  public static func zoneError(_ error: CKError) -> CloudKitZoneError {
    switch error.code {
    case .quotaExceeded: .storage(.quotaExceeded)
    case .requestRateLimited, .zoneBusy, .serviceUnavailable: .storage(.rateLimited(retryAfter: retryAfter(error)))
    case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted: .storage(.unauthenticated)
    case .networkUnavailable, .networkFailure, .serverResponseLost: .storage(.unavailable("iCloud could not be reached."))
    case .operationCancelled: .storage(cancelled)
    case .changeTokenExpired: .changeTokenExpired
    case .zoneNotFound: .zoneMissing(.missing)
    case .userDeletedZone: .zoneMissing(.purged)
    case .serverRecordChanged: .recordChanged
    case .unknownItem: .recordMissing
    case .limitExceeded: .limitExceeded
    case .partialFailure: partialFailure(error)
    case .badContainer, .missingEntitlement, .badDatabase, .permissionFailure: .storage(.unavailable("iCloud is not set up for this app (CloudKit error \(error.code.rawValue))."))
    default: .storage(.underlying("CloudKit refused the request (error \(error.code.rawValue))."))
    }
  }

  /// The per-item errors of a partial failure, keyed by the item (record id or zone id) CloudKit reports.
  public static func itemErrors(_ error: CKError) -> [AnyHashable: CloudKitZoneError] {
    guard let items = error.partialErrorsByItemID else { return [:] }
    return items.mapValues(zoneError)
  }

  /// The failure that decides what the whole call means: an item's error other than `batchRequestFailed`, the most severe first.
  static func partialFailure(_ error: CKError) -> CloudKitZoneError {
    let causes = (error.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }.filter { $0.code != .batchRequestFailed && $0.code != .partialFailure }
    let mapped = causes.map(zoneError)
    return mapped.min { severity($0) < severity($1) } ?? .storage(.unavailable("CloudKit failed part of a request."))
  }

  private static var cancelled: StorageError { .unavailable("The iCloud request was cancelled.") }

  private static func retryAfter(_ error: CKError) -> Duration? {
    guard let seconds = error.retryAfterSeconds, seconds.isFinite, seconds >= 0 else { return nil }
    return .milliseconds(Int64((seconds * 1000).rounded(.up)))
  }

  private static func severity(_ error: CloudKitZoneError) -> Int {
    switch error {
    case .zoneMissing: 0
    case .storage(.unauthenticated): 1
    case .storage(.quotaExceeded): 2
    case .storage(.rateLimited): 3
    case .changeTokenExpired: 4
    case .limitExceeded: 5
    case .storage: 6
    case .recordChanged, .recordMissing: 7
    }
  }
}

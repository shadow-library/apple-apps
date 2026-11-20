import CloudKit
import Foundation
import ShadowSync
import Testing

@testable import ShadowSyncCloudKit

@Suite("CloudKitErrorMap", TestTimeLimit.quick)
struct CloudKitErrorMapTests {
  private static let unavailable = CloudKitZoneError.storage(.unavailable("iCloud could not be reached."))

  @Test(
    "should map each CloudKit code to the provider's failure",
    arguments: [
      (CKError.Code.quotaExceeded, CloudKitZoneError.storage(.quotaExceeded)),
      (.requestRateLimited, .storage(.rateLimited(retryAfter: nil))),
      (.zoneBusy, .storage(.rateLimited(retryAfter: nil))),
      (.serviceUnavailable, .storage(.rateLimited(retryAfter: nil))),
      (.notAuthenticated, .storage(.unauthenticated)),
      (.accountTemporarilyUnavailable, .storage(.unauthenticated)),
      (.managedAccountRestricted, .storage(.unauthenticated)),
      (.networkUnavailable, unavailable),
      (.networkFailure, unavailable),
      (.serverResponseLost, unavailable),
      (.operationCancelled, .storage(.unavailable("The iCloud request was cancelled."))),
      (.changeTokenExpired, .changeTokenExpired),
      (.zoneNotFound, .zoneMissing(.missing)),
      (.userDeletedZone, .zoneMissing(.purged)),
      (.serverRecordChanged, .recordChanged),
      (.unknownItem, .recordMissing),
      (.limitExceeded, .limitExceeded),
    ])
  func mapsCodes(code: CKError.Code, expected: CloudKitZoneError) {
    #expect(CloudKitErrorMap.zoneError(CKError(code)) == expected)
  }

  @Test("should report set-up failures as unavailable, naming the code", arguments: [CKError.Code.badContainer, .missingEntitlement])
  func mapsSetupFailures(code: CKError.Code) {
    guard case .storage(.unavailable(let message)) = CloudKitErrorMap.zoneError(CKError(code)) else {
      Issue.record("expected unavailable")
      return
    }
    #expect(message.contains("\(code.rawValue)"))
  }

  @Test("should report other codes as underlying")
  func mapsOtherCodes() {
    #expect(CloudKitErrorMap.zoneError(CKError(.serverRejectedRequest)) == .storage(.underlying("CloudKit refused the request (error 15).")))
    #expect(CloudKitErrorMap.zoneError(CKError(.internalError)) == .storage(.underlying("CloudKit refused the request (error 1).")))
  }

  @Test("should carry the retry-after CloudKit asks for, rounded up to the millisecond")
  func carriesRetryAfter() {
    let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 2.5])
    #expect(CloudKitErrorMap.zoneError(error) == .storage(.rateLimited(retryAfter: .milliseconds(2500))))
    let busy = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 0.0004)])
    #expect(CloudKitErrorMap.zoneError(busy) == .storage(.rateLimited(retryAfter: .milliseconds(1))))
  }

  @Test("should unpack a partial failure per item and let the most severe cause decide, skipping batch-request failures")
  func unpacksPartialFailures() {
    let zone = CKRecordZone.ID(zoneName: "vault-default", ownerName: CKCurrentUserDefaultName)
    let first = CKRecord.ID(recordName: "o-1", zoneID: zone)
    let second = CKRecord.ID(recordName: "o-2", zoneID: zone)
    let third = CKRecord.ID(recordName: "o-3", zoneID: zone)
    let error = CKError(
      .partialFailure,
      userInfo: [
        CKPartialErrorsByItemIDKey: [
          first: CKError(.serverRecordChanged), second: CKError(.batchRequestFailed), third: CKError(.quotaExceeded, userInfo: [:]),
        ] as [AnyHashable: any Error]
      ])
    #expect(CloudKitErrorMap.zoneError(error) == .storage(.quotaExceeded))
    let items = CloudKitErrorMap.itemErrors(error)
    #expect(items[first] == .recordChanged)
    #expect(items[third] == .storage(.quotaExceeded))
    #expect(items.count == 3)
    let zoneGone = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [zone: CKError(.userDeletedZone)] as [AnyHashable: any Error]])
    #expect(CloudKitErrorMap.zoneError(zoneGone) == .zoneMissing(.purged))
  }

  @Test("should treat a partial failure without causes as unavailable")
  func emptyPartialFailure() {
    #expect(CloudKitErrorMap.zoneError(CKError(.partialFailure)) == .storage(.unavailable("CloudKit failed part of a request.")))
  }

  @Test("should map cancellation and foreign errors without losing the zone error already mapped")
  func mapsOtherErrors() {
    #expect(CloudKitErrorMap.zoneError(CancellationError()) == .storage(.unavailable("The iCloud request was cancelled.")))
    #expect(CloudKitErrorMap.zoneError(CloudKitZoneError.changeTokenExpired as any Error) == .changeTokenExpired)
    #expect(CloudKitErrorMap.zoneError(CKError(.zoneNotFound) as any Error) == .zoneMissing(.missing))
    #expect(CloudKitErrorMap.zoneError(URLError(.timedOut)) == .storage(.underlying("CloudKit failed: NSURLErrorDomain -1001")))
  }

  @Test("should turn seam failures into storage errors the engine understands")
  func mapsToStorageErrors() {
    #expect(CloudKitIndex.storageError(.storage(.quotaExceeded)) == .quotaExceeded)
    #expect(CloudKitIndex.storageError(.zoneMissing(.purged)) == .unavailable(CloudKitZoneLoss.purged.explanation))
    #expect(CloudKitStorageCondition.accountChanged(.signedOut(previous: "a")).error == .unauthenticated)
    guard case .unavailable = CloudKitStorageCondition.accountChanged(.switched(previous: "a", current: "b")).error else {
      Issue.record("a switched account must refuse calls as unavailable")
      return
    }
  }
}

import CloudKit
import Foundation
import ShadowSync
import Testing

@testable import ShadowSyncCloudKit

@Suite("CKZoneClient", TestTimeLimit.quick)
struct CKZoneClientTests {
  private static let zone = CKRecordZone.ID(zoneName: "vault-default", ownerName: CKCurrentUserDefaultName)

  @Test("should fail a feed page when a record failed to arrive, rather than move the token past it")
  func failsPagesWithMissingRecords() {
    let good = CKRecord.ID(recordName: "o-1", zoneID: Self.zone)
    let broken = CKRecord.ID(recordName: "o-2", zoneID: Self.zone)
    let page: [CKRecord.ID: Result<CKRecord, any Error>] = [
      good: .success(CKRecord(recordType: CloudKitRecordLayout.recordType, recordID: good)), broken: .failure(CKError(.serverRejectedRequest)),
    ]
    #expect(throws: CloudKitZoneError.storage(.underlying("CloudKit refused the request (error 15)."))) { try CKZoneClient.feedChanges(page) }
  }

  @Test("should skip records of another type and report a vault record without its fields as deleted")
  func readsFeedPages() throws {
    let foreign = CKRecord.ID(recordName: "x-1", zoneID: Self.zone)
    let hollow = CKRecord.ID(recordName: "o-3", zoneID: Self.zone)
    let page: [CKRecord.ID: Result<CKRecord, any Error>] = [
      foreign: .success(CKRecord(recordType: "Other", recordID: foreign)), hollow: .success(CKRecord(recordType: CloudKitRecordLayout.recordType, recordID: hollow)),
    ]
    let changes = try CKZoneClient.feedChanges(page)
    #expect(changes.changed.isEmpty)
    #expect(changes.deleted == [CloudKitRecordName("o-3")])
  }

  @Test("should allow one live client per container in a process")
  func claimsOneEnginePerContainer() {
    var first = CloudKitEngineClaim.claim("iCloud.com.shadow.apps.claim-test")
    #expect(first?.container == "iCloud.com.shadow.apps.claim-test")
    #expect(CloudKitEngineClaim.claim("iCloud.com.shadow.apps.claim-test") == nil)
    #expect(CloudKitEngineClaim.claim("iCloud.com.shadow.apps.claim-other") != nil)
    first = nil
    #expect(CloudKitEngineClaim.claim("iCloud.com.shadow.apps.claim-test") != nil)
  }
}

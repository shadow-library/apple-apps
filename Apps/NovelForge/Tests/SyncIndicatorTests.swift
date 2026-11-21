import Foundation
import ShadowCore
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncRuntime
import Testing

@testable import NovelForge

@Suite("Sync indicator", TestTimeLimit.standard)
struct SyncIndicatorTests {
  nonisolated private static let replica = ReplicaID("00000000-0000-7000-8000-000000000001")
  nonisolated private static let vaults = (VaultID("vault-a"), VaultID("vault-b"))
  nonisolated private static let moveNotice: VaultMoveNotice? = {
    guard let from = replica, let tag = ContentTag(String(repeating: "a", count: 32)), let base = BaseReference(upTo: 0, tag: tag, parts: 1) else { return nil }
    return VaultMoveNotice(from: from, to: ReplicaID(UUID()), base: base, frontier: [:], target: [:], movedMillis: 0)
  }()

  nonisolated static let reasons: [SyncAttentionReason] = {
    var reasons: [SyncAttentionReason] = [
      .quotaFull, .accountUnavailable, .accountChanged, .storageRemoved, .zoneLost(.missing), .zoneLost(.purged), .zoneLost(.encryptedDataReset),
      .vaultUnrecognized, .awaitingKey, .writingKeyMissing, .wrongClock(skew: .seconds(600), stopsUploads: true), .wrongClock(skew: .seconds(600), stopsUploads: false),
      .appUpdateRequired, .deviceLocked, .keychainUnavailable, .settingsUnreadable, .storageUnreachable, .failed(code: "sync.example"),
    ]
    if let replica { reasons.append(.keysMissing(replicas: [replica])) }
    if let expected = vaults.0, let found = vaults.1 { reasons.append(.vaultMismatch(expected: expected, found: found)) }
    if let notice = moveNotice { reasons += [.vaultMoved(notice), .moveInProgress] }
    return reasons
  }()

  @Test func shouldHideTheIndicatorWhileSyncIsOff() {
    #expect(SyncIndicator(.off) == nil)
  }

  @Test func shouldSayUpToDateAndSyncingWithoutAConsequence() throws {
    let upToDate = try #require(SyncIndicator(.upToDate))
    let syncing = try #require(SyncIndicator(.syncing))

    #expect(upToDate.tone == .upToDate && upToDate.headline == "Up to date" && upToDate.consequence == nil)
    #expect(syncing.tone == .syncing && syncing.headline == "Syncing" && syncing.consequence == nil)
    #expect(upToDate.accessibilityLabel == "Sync status: Up to date")
  }

  @Test func shouldSayWhatIsWrongAndWhatItStops() throws {
    let full = try #require(SyncIndicator(.attentionNeeded(.quotaFull)))
    let clock = try #require(SyncIndicator(.attentionNeeded(.wrongClock(skew: .seconds(600), stopsUploads: false))))
    let locked = try #require(SyncIndicator(.attentionNeeded(.deviceLocked)))

    #expect(full.tone == .attention)
    #expect(full.headline == "Sync storage is full")
    #expect(full.consequence == "Your changes are kept on this device, and your other devices will not see them until then.")
    #expect(clock.consequence == "Sync keeps running.")
    #expect(locked.headline == "Unlock this device to sync")
    #expect(locked.consequence == "Nothing syncs until then. Everything you do here is kept on this device.")
  }

  @Test func shouldNameTheDevicesWhoseChangesCannotBeReadAndSayWhatStops() throws {
    let phone = try #require(Self.replica)
    let (tablet, unnamed) = (ReplicaID(UUID()), ReplicaID(UUID()))
    let names = [phone: "Ada's iPhone", tablet: "Studio iPad"]

    let named = try #require(SyncIndicator(.attentionNeeded(.keysMissing(replicas: [phone, tablet])), deviceNames: names))
    let mixed = try #require(SyncIndicator(.attentionNeeded(.keysMissing(replicas: [phone, unnamed])), deviceNames: names))
    let unknown = try #require(SyncIndicator(.attentionNeeded(.keysMissing(replicas: [unnamed]))))

    #expect(named.headline == "Changes from Ada's iPhone and Studio iPad cannot be read yet")
    #expect(mixed.headline == "Changes from Ada's iPhone and one other device cannot be read yet")
    #expect(unknown.headline == "Changes from another device cannot be read yet")
    #expect(named.consequence == "Their changes do not appear here until the key arrives. Everything else keeps syncing.")
  }

  @Test func shouldDescribeAMoveFromAnotherDeviceAndAnUnfinishedMoveHere() throws {
    let notice = try #require(Self.moveNotice)

    #expect(try #require(SyncIndicator(.attentionNeeded(.vaultMoved(notice)))).headline == "Your library moved to another storage location")
    #expect(try #require(SyncIndicator(.attentionNeeded(.moveInProgress))).headline == "Moving your library did not finish")
  }

  @Test func shouldShowTheCodeOnlyForAnUnexpectedFailure() throws {
    #expect(try #require(SyncIndicator(.attentionNeeded(.failed(code: "sync.example")))).code == "sync.example")
    #expect(try #require(SyncIndicator(.attentionNeeded(.storageUnreachable))).code == nil)
    let keychain = try #require(SyncIndicator(.attentionNeeded(.keychainUnavailable)))
    #expect(keychain.headline == "Sync needs a signed build" && keychain.code == nil)
  }

  @Test(arguments: SyncIndicatorTests.reasons)
  func shouldWordEveryReasonFromTheSyncTable(reason: SyncAttentionReason) throws {
    let indicator = try #require(SyncIndicator(.attentionNeeded(reason)))
    let consequence = try #require(indicator.consequence)

    var keys = [indicator.detail, consequence]
    if case .keysMissing = reason {
      keys += ["Changes from %@ cannot be read yet", "another device", "one other device", "other devices"]
    } else {
      keys.append(indicator.headline)
    }
    for key in keys {
      #expect(Bundle.main.localizedString(forKey: key, value: "missing", table: "Sync") == key)
    }
  }
}

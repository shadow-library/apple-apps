import CloudKit
import Foundation
import OSLog
import ShadowCore
import Synchronization

/// The sync engine's delegate: it sends nothing, keeps the engine away from the vault zone's records, saves the engine's state and turns its
/// events into `CloudKitZoneEvent`s.
final class CKSyncEngineBridge: CKSyncEngineDelegate {
  private static let logger = Logger(category: "ShadowSyncCloudKit.Engine")

  let events = Broadcast<CloudKitZoneEvent>()

  private let zoneID: CKRecordZone.ID
  private let stateURL: URL
  private let hintedDuringFetch = Mutex(false)

  init(zoneID: CKRecordZone.ID, stateURL: URL) {
    self.zoneID = zoneID
    self.stateURL = stateURL
  }

  func savedState() -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let update):
      save(update.stateSerialization)
    case .accountChange(let change):
      guard let mapped = Self.accountChange(change.changeType) else { return }
      events.yield(.accountChanged(mapped))
    case .fetchedDatabaseChanges(let changes):
      for deletion in changes.deletions where deletion.zoneID == zoneID { events.yield(.zoneDeleted(Self.loss(deletion.reason))) }
      if changes.modifications.contains(where: { $0.zoneID == zoneID }) { hint() }
    case .fetchedRecordZoneChanges(let changes):
      if changes.modifications.contains(where: { $0.record.recordID.zoneID == zoneID }) || changes.deletions.contains(where: { $0.recordID.zoneID == zoneID }) { hint() }
    case .willFetchChanges:
      hintedDuringFetch.withLock { $0 = false }
    case .didFetchChanges:
      guard !hintedDuringFetch.withLock({ $0 }) else { return }
      hint()
    default:
      return
    }
  }

  func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    nil
  }

  func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
    var options = context.options
    options.scope = .allExcluding([zoneID])
    return options
  }

  private func hint() {
    hintedDuringFetch.withLock { $0 = true }
    events.yield(.remoteChange)
  }

  private func save(_ state: CKSyncEngine.State.Serialization) {
    do {
      try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic])
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var url = stateURL
      try url.setResourceValues(values)
    } catch {
      Self.logger.error("CloudKit engine state not saved: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func accountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) -> CloudKitAccountChange? {
    switch change {
    case .signIn(let current): .signedIn(current: current.recordName)
    case .signOut(let previous): .signedOut(previous: previous.recordName)
    case .switchAccounts(let previous, let current): .switched(previous: previous.recordName, current: current.recordName)
    @unknown default: nil
    }
  }

  private static func loss(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> CloudKitZoneLoss {
    switch reason {
    case .purged: .purged
    case .encryptedDataReset: .encryptedDataReset
    case .deleted: .missing
    @unknown default: .missing
    }
  }
}

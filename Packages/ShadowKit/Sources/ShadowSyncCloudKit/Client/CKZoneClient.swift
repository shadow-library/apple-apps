import CloudKit
import Foundation
import ShadowSync

/// The zone of a vault in the user's private database. Record writes, reads and deletes go straight to `CKDatabase` so each call returns its own
/// per-record outcome; the zone's change feed is read with `recordZoneChanges(desiredKeys:)`, so listing never downloads assets and an expired token
/// surfaces as `changeTokenExpired`. A `CKSyncEngine` owns the database subscription, push-driven and scheduled fetches of database changes and
/// account events, and its state is saved at `engineStateURL`; it is told to skip this zone's records, which this client fetches itself.
/// Construct it only in builds that have the iCloud (CloudKit) and push capabilities: creating a container or a sync engine without the
/// entitlement is reported to raise an exception. CloudKit's production environment allows one sync engine per database, so one client per
/// container may live in a process; another init throws `engineAlreadyRunning` until the first is released.
public final class CKZoneClient: CloudKitZoneClient {
  public let configuration: CloudKitConfiguration

  private let container: CKContainer
  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID
  private let scratchDirectory: URL
  private let bridge: CKSyncEngineBridge
  private let engine: CKSyncEngine
  private let claim: CloudKitEngineClaim

  /// `engineStateURL` and `scratchDirectory` must lie outside the vault directory; the state file is excluded from backups.
  public init(
    configuration: CloudKitConfiguration, engineStateURL: URL, scratchDirectory: URL = FileManager.default.temporaryDirectory
  ) throws(CloudKitConfigurationError) {
    guard let claim = CloudKitEngineClaim.claim(configuration.containerIdentifier) else { throw .engineAlreadyRunning(configuration.containerIdentifier) }
    self.claim = claim
    let container = CKContainer(identifier: configuration.containerIdentifier)
    let database = container.privateCloudDatabase
    let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
    let bridge = CKSyncEngineBridge(zoneID: zoneID, stateURL: engineStateURL)
    self.configuration = configuration
    self.container = container
    self.database = database
    self.zoneID = zoneID
    self.scratchDirectory = scratchDirectory
    self.bridge = bridge
    engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: bridge.savedState(), delegate: bridge))
  }

  public func ensureZone() async throws(CloudKitZoneError) {
    let results: [CKRecordZone.ID: Result<CKRecordZone, any Error>]
    do {
      results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []).saveResults
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    switch results[zoneID] {
    case .success: return
    case .failure(let error): throw CloudKitErrorMap.zoneError(error)
    case nil: throw .storage(.unavailable("iCloud did not answer for the vault's zone."))
    }
  }

  public func fetchChanges(since token: CloudKitChangeToken?) async throws(CloudKitZoneError) -> CloudKitChangeBatch {
    var serverToken: CKServerChangeToken?
    if let token {
      guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token.data) else { throw .changeTokenExpired }
      serverToken = decoded
    }
    let response:
      (
        modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>], deletions: [CKDatabase.RecordZoneChange.Deletion],
        changeToken: CKServerChangeToken, moreComing: Bool
      )
    do {
      response = try await database.recordZoneChanges(
        inZoneWith: zoneID, since: serverToken, desiredKeys: [CloudKitRecordLayout.pathField, CloudKitRecordLayout.sizeField])
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    var (changed, deleted) = try Self.feedChanges(response.modificationResultsByID.mapValues { $0.map(\.record) })
    deleted += response.deletions.map { CloudKitRecordName($0.recordID.recordName) }
    let encoded: Data
    do {
      encoded = try NSKeyedArchiver.archivedData(withRootObject: response.changeToken, requiringSecureCoding: true)
    } catch {
      throw .storage(.underlying("The iCloud change token could not be kept."))
    }
    return CloudKitChangeBatch(changed: changed, deleted: deleted, token: CloudKitChangeToken(data: encoded), moreComing: response.moreComing)
  }

  public func fetch(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitObjectRecord, CloudKitZoneError>] {
    guard !names.isEmpty else { return [:] }
    let results: [CKRecord.ID: Result<CKRecord, any Error>]
    do {
      results = try await database.records(for: names.map(recordID))
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    var outcomes: [CloudKitRecordName: Result<CloudKitObjectRecord, CloudKitZoneError>] = [:]
    for name in names {
      switch results[recordID(name)] {
      case .success(let record): outcomes[name] = Self.object(from: record, name: name)
      case .failure(let error): outcomes[name] = .failure(CloudKitErrorMap.zoneError(error))
      case nil: outcomes[name] = .failure(.recordMissing)
      }
    }
    return outcomes
  }

  public func save(
    _ records: [CloudKitObjectRecord], mode: CloudKitSaveMode
  ) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>] {
    guard !records.isEmpty else { return [:] }
    let directory = scratchDirectory.appending(path: "shadow-cloudkit-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prepared = try prepare(records, in: directory)
    let results: [CKRecord.ID: Result<CKRecord, any Error>]
    do {
      results = try await database.modifyRecords(saving: prepared, deleting: [], savePolicy: mode == .ifAbsent ? .ifServerRecordUnchanged : .allKeys, atomically: false)
        .saveResults
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    var outcomes: [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>] = [:]
    for record in records {
      switch results[recordID(record.name)] {
      case .success(let saved):
        outcomes[record.name] = Self.summary(of: saved).map { .success($0) } ?? .failure(.storage(.underlying("iCloud saved \(record.path) without its fields.")))
      case .failure(let error): outcomes[record.name] = .failure(CloudKitErrorMap.zoneError(error))
      case nil: outcomes[record.name] = .failure(.storage(.unavailable("iCloud did not answer for \(record.path).")))
      }
    }
    return outcomes
  }

  public func delete(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<Void, CloudKitZoneError>] {
    guard !names.isEmpty else { return [:] }
    let results: [CKRecord.ID: Result<Void, any Error>]
    do {
      results = try await database.modifyRecords(saving: [], deleting: names.map(recordID), savePolicy: .allKeys, atomically: false).deleteResults
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    var outcomes: [CloudKitRecordName: Result<Void, CloudKitZoneError>] = [:]
    for name in names {
      switch results[recordID(name)] {
      case .success: outcomes[name] = .success(())
      case nil: outcomes[name] = .failure(.storage(.unavailable("iCloud did not answer for \(name).")))
      case .failure(let error):
        let mapped = CloudKitErrorMap.zoneError(error)
        outcomes[name] = mapped == .recordMissing ? .success(()) : .failure(mapped)
      }
    }
    return outcomes
  }

  public func accountStatus() async throws(CloudKitZoneError) -> CloudKitAccountStatus {
    let status: CKAccountStatus
    do {
      status = try await container.accountStatus()
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
    switch status {
    case .available: return .available
    case .noAccount: return .noAccount
    case .restricted: return .restricted
    case .temporarilyUnavailable: return .temporarilyUnavailable
    case .couldNotDetermine: return .couldNotDetermine
    @unknown default: return .couldNotDetermine
    }
  }

  public func currentUserRecordName() async throws(CloudKitZoneError) -> String {
    do {
      return try await container.userRecordID().recordName
    } catch {
      throw CloudKitErrorMap.zoneError(error)
    }
  }

  public func events() -> AsyncStream<CloudKitZoneEvent> {
    bridge.events.stream()
  }

  /// Asks the sync engine to fetch database changes now, as on foregrounding; its events follow on `events()`.
  public func refresh() async {
    try? await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .allExcluding([zoneID])))
  }

  private func recordID(_ name: CloudKitRecordName) -> CKRecord.ID {
    CKRecord.ID(recordName: name.rawValue, zoneID: zoneID)
  }

  private func prepare(_ records: [CloudKitObjectRecord], in directory: URL) throws(CloudKitZoneError) -> [CKRecord] {
    var prepared: [CKRecord] = []
    for record in records {
      let ckRecord = CKRecord(recordType: CloudKitRecordLayout.recordType, recordID: recordID(record.name))
      ckRecord[CloudKitRecordLayout.pathField] = record.path
      ckRecord[CloudKitRecordLayout.sizeField] = Int64(record.size)
      switch record.payload {
      case .inline(let bytes):
        ckRecord[CloudKitRecordLayout.bytesField] = bytes
        ckRecord[CloudKitRecordLayout.partsField] = nil as [CKAsset]?
      case .parts(let parts):
        ckRecord[CloudKitRecordLayout.partsField] = try assets(parts, for: record.name, in: directory)
        ckRecord[CloudKitRecordLayout.bytesField] = nil as Data?
      }
      prepared.append(ckRecord)
    }
    return prepared
  }

  private func assets(_ parts: [Data], for name: CloudKitRecordName, in directory: URL) throws(CloudKitZoneError) -> [CKAsset] {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return try parts.enumerated().map { index, part in
        let url = directory.appending(path: "\(name.rawValue)-\(index)")
        try part.write(to: url, options: [.atomic])
        return CKAsset(fileURL: url)
      }
    } catch {
      throw .storage(.underlying("The object's parts could not be staged for iCloud: \(error.localizedDescription)"))
    }
  }

  static func summary(of record: CKRecord) -> CloudKitRecordSummary? {
    guard let path: String = record[CloudKitRecordLayout.pathField], let size: Int64 = record[CloudKitRecordLayout.sizeField], let modified = record.modificationDate
    else { return nil }
    return CloudKitRecordSummary(name: CloudKitRecordName(record.recordID.recordName), path: path, size: Int(size), modified: modified)
  }

  /// Parts win when their sizes add up to the stated size, so a field an overwrite could not clear never decides what is read.
  static func object(from record: CKRecord, name: CloudKitRecordName) -> Result<CloudKitObjectRecord, CloudKitZoneError> {
    guard record.recordType == CloudKitRecordLayout.recordType, let summary = summary(of: record) else {
      return .failure(.storage(.underlying("The iCloud record \(name) is not a vault object.")))
    }
    if let assets: [CKAsset] = record[CloudKitRecordLayout.partsField], !assets.isEmpty {
      var parts: [Data] = []
      for asset in assets {
        guard let url = asset.fileURL, let data = try? Data(contentsOf: url) else {
          return .failure(.storage(.unavailable("A part of \(summary.path) was not downloaded from iCloud.")))
        }
        parts.append(data)
      }
      if parts.reduce(0, { $0 + $1.count }) == summary.size { return .success(CloudKitObjectRecord(name: name, path: summary.path, size: summary.size, payload: .parts(parts))) }
    }
    let bytes: Data = record[CloudKitRecordLayout.bytesField] ?? Data()
    return .success(CloudKitObjectRecord(name: name, path: summary.path, size: summary.size, payload: .inline(bytes)))
  }

  /// A record that failed to arrive fails the page, so the token does not move past it and the next catch-up asks again.
  static func feedChanges(
    _ modifications: [CKRecord.ID: Result<CKRecord, any Error>]
  ) throws(CloudKitZoneError) -> (changed: [CloudKitRecordSummary], deleted: [CloudKitRecordName]) {
    var changed: [CloudKitRecordSummary] = []
    var deleted: [CloudKitRecordName] = []
    for (id, result) in modifications.sorted(by: { $0.key.recordName.utf8.lexicographicallyPrecedes($1.key.recordName.utf8) }) {
      switch result {
      case .success(let record):
        guard record.recordType == CloudKitRecordLayout.recordType else { continue }
        if let summary = summary(of: record) { changed.append(summary) } else { deleted.append(CloudKitRecordName(id.recordName)) }
      case .failure(let error):
        throw CloudKitErrorMap.zoneError(error)
      }
    }
    return (changed, deleted)
  }
}

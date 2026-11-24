import Foundation
import ShadowCore
import ShadowStore

/// A device of the vault, as the app identifies it: an id kept for the install and the name the owner sees.
public struct HealthReaderDevice: Sendable, Hashable {
  public let id: UUID
  public let name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public enum HealthReaderClaim: Sendable, Equatable {
  case claimed(previous: HealthReaderDesignation?)
  case alreadyReader
  case heldByAnother(HealthReaderDesignation)
}

/// The vault's Health settings, in the main store. One device reads Health; another asks the owner before it takes over (`heldByAnother`, then a claim
/// with `takingOver`). Two claims made at once resolve to the later one, and a device that lost the designation stops reading at its next import.
public enum HealthSettings {
  public static func designation<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(MemoirRecordError) -> HealthReaderDesignation? {
    try settings(in: source)?.reader
  }

  /// An absent or unreadable record leaves Activity on the device.
  public static func isActivityOnICloud<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(StoreError) -> Bool {
    try HealthSettingsRecord.read(key: .healthSettings, in: source).entry?.record.isActivityOnICloud ?? false
  }

  public static func claim(_ device: HealthReaderDevice, takingOver: Bool = false, atMillis: Int64, in transaction: inout WriteTransaction) throws(MemoirRecordError)
    -> HealthReaderClaim
  {
    let current = try designation(in: transaction)
    if let current {
      if current.device == device.id { return .alreadyReader }
      if !takingOver { return .heldByAnother(current) }
    }
    try write(in: &transaction) { $0.reader = HealthReaderDesignation(device: device.id, name: device.name, claimedAtMillis: atMillis) }
    return .claimed(previous: current)
  }

  /// Gives the designation up when this device holds it, as when the owner turns every Health metric off here.
  @discardableResult
  public static func release(_ device: HealthReaderDevice, in transaction: inout WriteTransaction) throws(MemoirRecordError) -> Bool {
    guard try designation(in: transaction)?.device == device.id else { return false }
    try write(in: &transaction) { $0.reader = nil }
    return true
  }

  /// Clears the designation whichever device holds it, as when the owner turns the Body module off; that device stops at its next import.
  @discardableResult
  public static func clearReader(in transaction: inout WriteTransaction) throws(MemoirRecordError) -> HealthReaderDesignation? {
    guard let current = try designation(in: transaction) else { return nil }
    try write(in: &transaction) { $0.reader = nil }
    return current
  }

  public static func setActivityOnICloud(_ isOn: Bool, in transaction: inout WriteTransaction) throws(MemoirRecordError) {
    guard try settings(in: transaction)?.activityOnICloud != isOn else { return }
    try write(in: &transaction) { $0.activityOnICloud = isOn }
  }

  private static func settings<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(MemoirRecordError) -> HealthSettingsRecord? {
    let reading: MemoirReading<MemoirEntry<HealthSettingsRecord>>
    do throws(StoreError) {
      reading = try HealthSettingsRecord.read(key: .healthSettings, in: source)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent: return nil
    case .readable(let entry): return entry.record
    case .unreadable(let reason): throw .unreadable(MemoirKey.healthSettings.ref, reason)
    }
  }

  /// Creating the record writes only the member being set, so a concurrent first write of the other member on another device survives the merge.
  private static func write(in transaction: inout WriteTransaction, _ change: (inout HealthSettingsRecord) -> Void) throws(MemoirRecordError) {
    guard try settings(in: transaction) != nil else {
      var record = HealthSettingsRecord()
      change(&record)
      try record.create(in: &transaction)
      return
    }
    try HealthSettingsRecord.edit(MemoirKey.healthSettings.ref, in: &transaction) { record throws(MemoirRecordError) in change(&record) }
  }
}

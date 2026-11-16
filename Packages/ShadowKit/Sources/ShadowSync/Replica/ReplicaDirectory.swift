import Foundation
import ShadowCore
import ShadowStore

public enum ReplicaState: String, Sendable {
  case active
  case retired
}

public struct ReplicaEntry: Sendable, Equatable {
  public let replica: ReplicaID
  public let state: ReplicaState
  public let name: String?
  public let platform: String?
  /// When two copies retire the same id, the register keeps one successor, so the chain is a hint and not a complete history.
  public let successor: ReplicaID?
  public let created: Int64?

  init?(key: EntityKey, record: RecordState) {
    typealias Field = SyncKernelSchema.Field
    guard let replica = ReplicaID(key.rawValue), let state = record.text(Field.state).flatMap(ReplicaState.init(rawValue:)) else { return nil }
    self.replica = replica
    self.state = state
    name = record.text(Field.name)
    platform = record.text(Field.platform)
    successor = record.text(Field.successor).flatMap(ReplicaID.init)
    created = record[field: Field.created]?.value.intValue
  }
}

public struct ReplicaDirectory: Sendable, Equatable {
  public let replicas: [ReplicaEntry]
  /// Floors are read from entity keys, purged entities included, so neither a purge nor a rewritten field can lower them.
  public let minimumSchema: Int?
  public let keyFloor: KeyID?
  public let recovery: RecoveryRecipient?

  public init(state: VaultState) {
    var replicas = [ReplicaEntry]()
    var schemaFloors = [Int]()
    var keyFloors = [KeyID]()
    var recipients = [(recipient: RecoveryRecipient, created: Int64)]()
    for ref in state.refs {
      switch ref.kind {
      case SyncKernelSchema.schemaFloorKind:
        if let version = SyncKernelSchema.schemaFloor(of: ref.key) { schemaFloors.append(version) }
      case SyncKernelSchema.keyFloorKind:
        if let key = SyncKernelSchema.keyFloor(of: ref.key) { keyFloors.append(key) }
      case SyncKernelSchema.replicaKind:
        guard case .record(let record)? = state.state(of: ref), let entry = ReplicaEntry(key: ref.key, record: record) else { continue }
        replicas.append(entry)
      case SyncKernelSchema.recoveryKind:
        guard case .record(let record)? = state.state(of: ref), let candidate = Self.activeRecipient(ref, record) else { continue }
        recipients.append(candidate)
      default:
        continue
      }
    }
    self.replicas = replicas.sorted { $0.replica < $1.replica }
    minimumSchema = schemaFloors.max()
    keyFloor = keyFloors.max()
    recovery = recipients.max { ($0.created, $0.recipient.id) < ($1.created, $1.recipient.id) }?.recipient
  }

  public func entry(for replica: ReplicaID) -> ReplicaEntry? {
    replicas.first { $0.replica == replica }
  }

  public func isRetired(_ replica: ReplicaID) -> Bool {
    entry(for: replica)?.state == .retired
  }

  static func isRetired(_ state: EntityState?) -> Bool {
    guard case .record(let record)? = state else { return false }
    return record.text(SyncKernelSchema.Field.state) == ReplicaState.retired.rawValue
  }

  private static func activeRecipient(_ ref: EntityRef, _ record: RecordState) -> (recipient: RecoveryRecipient, created: Int64)? {
    typealias Field = SyncKernelSchema.Field
    guard record.text(Field.state) == ReplicaState.active.rawValue, let created = record[field: Field.created]?.value.intValue else { return nil }
    guard let publicKey = record.text(Field.publicKey).flatMap({ Data(base64Encoded: $0) }), let sealingKey = record.text(Field.sealingKey).flatMap({ Data(base64Encoded: $0) })
    else { return nil }
    guard let recipient = RecoveryRecipient(publicKey: publicKey, sealingKey: sealingKey), SyncKernelSchema.recoveryRef(recipient.id) == ref else { return nil }
    return (recipient, created)
  }
}

extension ReplicaDirectory {
  public static func declareActive(_ replica: ReplicaID, name: String, platform: String, createdMillis: Int64, in transaction: inout WriteTransaction) throws(StoreError) {
    typealias Field = SyncKernelSchema.Field
    let ref = SyncKernelSchema.replicaRef(replica)
    let stored = try lookup(ref, in: transaction)
    guard !stored.isPurged else { return }
    let existing = stored.record
    var fields = [String: JSONValue]()
    if existing?.text(Field.state) == nil { fields[Field.state] = .string(ReplicaState.active.rawValue) }
    if existing?.text(Field.name) != name { fields[Field.name] = .string(name) }
    if existing?.text(Field.platform) != platform { fields[Field.platform] = .string(platform) }
    if existing?[field: Field.created] == nil { fields[Field.created] = .int(createdMillis) }
    try write(ref, fields, in: &transaction)
  }

  public static func retire(_ replica: ReplicaID, successor: ReplicaID?, in transaction: inout WriteTransaction) throws(StoreError) {
    typealias Field = SyncKernelSchema.Field
    let ref = SyncKernelSchema.replicaRef(replica)
    let stored = try lookup(ref, in: transaction)
    guard !stored.isPurged else { return }
    let existing = stored.record
    var fields = [String: JSONValue]()
    if existing?.text(Field.state) != ReplicaState.retired.rawValue { fields[Field.state] = .string(ReplicaState.retired.rawValue) }
    if let successor, existing?.text(Field.successor) != successor.description { fields[Field.successor] = .string(successor.description) }
    try write(ref, fields, in: &transaction)
  }

  public func raiseSchemaFloor(to version: Int, in transaction: inout WriteTransaction) throws(StoreError) {
    guard version >= 0 else { throw .invalidChange("a schema floor of \(version) is negative") }
    if let minimumSchema, version <= minimumSchema { return }
    let ref = SyncKernelSchema.schemaFloorRef(version)
    guard case .absent = try Self.lookup(ref, in: transaction) else { return }
    try Self.write(ref, [SyncKernelSchema.Field.version: .int(Int64(version))], in: &transaction)
  }

  public func raiseKeyFloor(to key: KeyID, in transaction: inout WriteTransaction) throws(StoreError) {
    if let keyFloor, key <= keyFloor { return }
    let ref = SyncKernelSchema.keyFloorRef(key)
    guard case .absent = try Self.lookup(ref, in: transaction) else { return }
    try Self.write(ref, [SyncKernelSchema.Field.key: .string(key.description)], in: &transaction)
  }

  public static func setRecovery(_ recipient: RecoveryRecipient, createdMillis: Int64, in transaction: inout WriteTransaction) throws(StoreError) {
    typealias Field = SyncKernelSchema.Field
    let ref = SyncKernelSchema.recoveryRef(recipient.id)
    let stored = try lookup(ref, in: transaction)
    guard !stored.isPurged else { return }
    let existing = stored.record
    var fields = [String: JSONValue]()
    if existing?.text(Field.publicKey) == nil { fields[Field.publicKey] = .string(recipient.publicKey.base64EncodedString()) }
    if existing?.text(Field.sealingKey) == nil { fields[Field.sealingKey] = .string(recipient.sealingKey.base64EncodedString()) }
    if existing?.text(Field.state) == nil { fields[Field.state] = .string(ReplicaState.active.rawValue) }
    if existing?[field: Field.created] == nil { fields[Field.created] = .int(createdMillis) }
    try write(ref, fields, in: &transaction)
  }

  public static func retireRecovery(recipientID: String, in transaction: inout WriteTransaction) throws(StoreError) {
    let ref = SyncKernelSchema.recoveryRef(recipientID)
    let stored = try lookup(ref, in: transaction)
    guard !stored.isPurged, stored.record?.text(SyncKernelSchema.Field.state) != ReplicaState.retired.rawValue else { return }
    try write(ref, [SyncKernelSchema.Field.state: .string(ReplicaState.retired.rawValue)], in: &transaction)
  }

  private static func lookup(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) -> StoredRecord {
    switch try transaction.state(of: ref) {
    case .purged: .purged
    case .record(let record): .stored(record)
    case .appended, .revisioned, nil: .absent
    }
  }

  private static func write(_ ref: EntityRef, _ fields: [String: JSONValue], in transaction: inout WriteTransaction) throws(StoreError) {
    guard !fields.isEmpty else { return }
    _ = try transaction.set(ref, fields)
  }
}

private enum StoredRecord {
  case absent
  case stored(RecordState)
  case purged

  var record: RecordState? {
    guard case .stored(let record) = self else { return nil }
    return record
  }

  var isPurged: Bool {
    guard case .purged = self else { return false }
    return true
  }
}

extension RecordState {
  fileprivate func text(_ name: String) -> String? {
    self[field: name]?.value.stringValue
  }
}

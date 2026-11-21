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
  /// The wall time, in milliseconds, of the record that retired it, as the retiring device's clock stamped it.
  public let retired: Int64?

  init?(key: EntityKey, record: RecordState) {
    typealias Field = SyncKernelSchema.Field
    guard let replica = ReplicaID(key.rawValue), let state = record.text(Field.state).flatMap(ReplicaState.init(rawValue:)) else { return nil }
    self.replica = replica
    self.state = state
    name = record.text(Field.name)
    platform = record.text(Field.platform)
    successor = record.text(Field.successor).flatMap(ReplicaID.init)
    created = record[field: Field.created]?.value.intValue
    retired = state == .retired ? record[field: Field.state]?.clock.wallMillis : nil
  }
}

/// Every base of `adopter` from `at` on holds the files of `adopted` it folded: every change numbered up to `through`, and a complete base of `adopted` reaching `baseUpTo` (0 when none).
public struct SyncAdoptionFact: Sendable, Hashable {
  public let adopted: ReplicaID
  public let adopter: ReplicaID
  public let through: Int64
  public let at: Int64
  public let baseUpTo: Int64

  public init(adopted: ReplicaID, adopter: ReplicaID, through: Int64, at: Int64, baseUpTo: Int64) {
    self.adopted = adopted
    self.adopter = adopter
    self.through = through
    self.at = at
    self.baseUpTo = baseUpTo
  }
}

/// A recovery recipient the vault has recorded; `recovery` is the newest active one, and any other active one was superseded by a concurrent setup.
public struct RecoveryEntry: Sendable, Equatable {
  public let recipientID: String
  public let state: ReplicaState
  public let created: Int64
}

public struct ReplicaDirectory: Sendable, Equatable {
  public let replicas: [ReplicaEntry]
  /// Floors are read from entity keys, purged entities included, so neither a purge nor a rewritten field can lower them.
  public let minimumSchema: Int?
  public let keyFloor: KeyID?
  public let recovery: RecoveryRecipient?
  public let recoveries: [RecoveryEntry]
  /// Read from entity keys, purged entities included; every fact stays valid, however many there are about one replica.
  public let adoptions: [SyncAdoptionFact]

  public init(state: VaultState) {
    self.init(entities: state.refs.compactMap { ref in state.state(of: ref).map { (ref: ref, state: $0) } })
  }

  init(entities: [(ref: EntityRef, state: EntityState)]) {
    var replicas = [ReplicaEntry]()
    var schemaFloors = [Int]()
    var keyFloors = [KeyID]()
    var recipients = [(recipient: RecoveryRecipient, created: Int64)]()
    var recoveries = [RecoveryEntry]()
    var adoptions = Set<SyncAdoptionFact>()
    for (ref, state) in entities {
      switch ref.kind {
      case SyncKernelSchema.schemaFloorKind:
        if let version = SyncKernelSchema.schemaFloor(of: ref.key) { schemaFloors.append(version) }
      case SyncKernelSchema.keyFloorKind:
        if let key = SyncKernelSchema.keyFloor(of: ref.key) { keyFloors.append(key) }
      case SyncKernelSchema.replicaKind:
        guard case .record(let record) = state, let entry = ReplicaEntry(key: ref.key, record: record) else { continue }
        replicas.append(entry)
      case SyncKernelSchema.recoveryKind:
        guard case .record(let record) = state, let entry = Self.recoveryEntry(ref, record) else { continue }
        recoveries.append(RecoveryEntry(recipientID: entry.recipient.id, state: entry.state, created: entry.created))
        if entry.state == .active { recipients.append((entry.recipient, entry.created)) }
      case SyncKernelSchema.adoptionKind:
        if let fact = SyncKernelSchema.adoption(of: ref.key) { adoptions.insert(fact) }
      default:
        continue
      }
    }
    self.replicas = replicas.sorted { $0.replica < $1.replica }
    minimumSchema = schemaFloors.max()
    keyFloor = keyFloors.max()
    recovery = recipients.max { ($0.created, $0.recipient.id) < ($1.created, $1.recipient.id) }?.recipient
    self.recoveries = recoveries.sorted { ($0.created, $0.recipientID) < ($1.created, $1.recipientID) }
    self.adoptions = adoptions.sorted { ($0.adopted, $0.adopter, $0.at, $0.through, $0.baseUpTo) < ($1.adopted, $1.adopter, $1.at, $1.through, $1.baseUpTo) }
  }

  public static func read(in transaction: ReadTransaction) throws(StoreError) -> ReplicaDirectory {
    var entities: [(ref: EntityRef, state: EntityState)] = []
    for kind in SyncKernelSchema.kinds { entities += try transaction.states(ofKind: kind) }
    return ReplicaDirectory(entities: entities)
  }

  public static func read(in transaction: borrowing WriteTransaction) throws(StoreError) -> ReplicaDirectory {
    var entities: [(ref: EntityRef, state: EntityState)] = []
    for kind in SyncKernelSchema.kinds { entities += try transaction.states(ofKind: kind) }
    return ReplicaDirectory(entities: entities)
  }

  static func adoptions(in transaction: ReadTransaction) throws(StoreError) -> [SyncAdoptionFact] {
    ReplicaDirectory(entities: try transaction.states(ofKind: SyncKernelSchema.adoptionKind)).adoptions
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

  private static func recoveryEntry(_ ref: EntityRef, _ record: RecordState) -> (recipient: RecoveryRecipient, state: ReplicaState, created: Int64)? {
    typealias Field = SyncKernelSchema.Field
    guard let state = record.text(Field.state).flatMap(ReplicaState.init(rawValue:)), let created = record[field: Field.created]?.value.intValue else { return nil }
    guard let publicKey = record.text(Field.publicKey).flatMap({ Data(base64Encoded: $0) }), let sealingKey = record.text(Field.sealingKey).flatMap({ Data(base64Encoded: $0) })
    else { return nil }
    guard let recipient = RecoveryRecipient(publicKey: publicKey, sealingKey: sealingKey), SyncKernelSchema.recoveryRef(recipient.id) == ref else { return nil }
    return (recipient, state, created)
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

  /// Written once per fact; a purged fact is still read from its key.
  public static func recordAdoption(_ fact: SyncAdoptionFact, in transaction: inout WriteTransaction) throws(StoreError) {
    let ref = SyncKernelSchema.adoptionRef(fact)
    guard case .absent = try lookup(ref, in: transaction) else { return }
    typealias Field = SyncKernelSchema.Field
    try write(ref, [Field.through: .int(fact.through), Field.at: .int(fact.at), Field.baseUpTo: .int(fact.baseUpTo)], in: &transaction)
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

import Foundation
import ShadowCore
import ShadowStore

// Like EntityEdit: `.keep` leaves a field, `.set(value)` writes it and `.set(nil)` clears it; the initialiser sets what it is given and keeps the rest
public struct EntityDetails: Sendable, Equatable {
  public var significance: FieldChange<StoredEnum<EntitySignificance>?>
  public var status: FieldChange<String?>
  public var origin: FieldChange<StoredEnum<EntityOrigin>?>
  public var notes: FieldChange<String?>
  public var motivation: FieldChange<String?>
  public var body: FieldChange<String?>
  public var appearance: FieldChange<String?>

  public init(
    significance: EntitySignificance? = nil, status: String? = nil, origin: EntityOrigin? = nil, notes: String? = nil, motivation: String? = nil, body: String? = nil,
    appearance: String? = nil
  ) {
    self.significance = significance.map { .set(.known($0)) } ?? .keep
    self.status = status.map { .set($0) } ?? .keep
    self.origin = origin.map { .set(.known($0)) } ?? .keep
    self.notes = notes.map { .set($0) } ?? .keep
    self.motivation = motivation.map { .set($0) } ?? .keep
    self.body = body.map { .set($0) } ?? .keep
    self.appearance = appearance.map { .set($0) } ?? .keep
  }

  var isEmpty: Bool { self == EntityDetails() }
}

// apps/novel-forge-server/src/modules/bible/entity/entity.service.ts; aliases, relationships, states, events and images have no kind in schema v1
public enum Entities {
  // entity.service.ts:46: inserts, or on a live key updates every field the call names (the type is kept); a removed key is created anew
  public static func create(
    novel: UUID, entity: String, type: EntityType, name: String, _ details: EntityDetails = EntityDetails(), in transaction: inout WriteTransaction
  ) throws(DomainError) {
    try requireKey(entity, field: "entityKey")
    try requireNonBlank(name, field: "name")
    try transaction.requireNovel(novel)
    let ref = EntityRecord.ref(novel: novel, entity: entity)
    switch try transaction.presence(ref, as: EntityRecord.self) {
    case .live(let existing):
      try transaction.edit(EntityRecord.self, ref, difference(from: existing, to: applying(details, name: name, to: existing)).fields)
    case .removed, .absent:
      let record = EntityRecord(novel: novel, entity: entity, type: .known(type), name: name)
      try transaction.create(applying(details, name: name, to: record))
    }
  }

  // entity.service.ts:46 upserts; the author's create refuses a live key instead of silently editing it, and a removed key is created anew
  public static func createNew(
    novel: UUID, entity: String, type: EntityType, name: String, _ details: EntityDetails = EntityDetails(), in transaction: inout WriteTransaction
  ) throws(DomainError) {
    try requireKey(entity, field: "entityKey")
    try requireNonBlank(name, field: "name")
    try transaction.requireNovel(novel)
    let ref = EntityRecord.ref(novel: novel, entity: entity)
    if case .live(let existing) = try transaction.presence(ref, as: EntityRecord.self) { throw .entityExists(existing.entity) }
    try transaction.create(applying(details, name: name, to: EntityRecord(novel: novel, entity: entity, type: .known(type), name: name)))
  }

  // entity.service.ts:119: UpdateEntityBody needs at least one property; a missing or removed entity is ENT_001
  public static func edit(novel: UUID, entity: String, name: String? = nil, _ details: EntityDetails = EntityDetails(), in transaction: inout WriteTransaction) throws(DomainError)
  {
    guard name != nil || !details.isEmpty else { throw .noChanges }
    if let name { try requireNonBlank(name, field: "name") }
    let ref = EntityRecord.ref(novel: novel, entity: entity)
    guard case .live(let existing) = try transaction.presence(ref, as: EntityRecord.self) else { throw .entityNotFound(entity) }
    try transaction.edit(EntityRecord.self, ref, difference(from: existing, to: applying(details, name: name ?? existing.name, to: existing)).fields)
  }

  // entity.service.ts:261: the reference deletes the row; here the record is marked removed and its dependants are hidden by derivation
  public static func remove(novel: UUID, entity: String, in transaction: inout WriteTransaction) throws(DomainError) {
    let ref = EntityRecord.ref(novel: novel, entity: entity)
    guard case .live = try transaction.presence(ref, as: EntityRecord.self) else { throw .entityNotFound(entity) }
    try transaction.remove(EntityRecord.self, ref)
  }

  public static func restore(novel: UUID, entity: String, in transaction: inout WriteTransaction) throws(DomainError) {
    switch try transaction.presence(EntityRecord.ref(novel: novel, entity: entity), as: EntityRecord.self) {
    case .removed(let record): try transaction.restore(record)
    case .live: return
    case .absent: throw .entityNotFound(entity)
    }
  }

  // entity.service.ts:110
  public static func get<Transaction: StateReading & ~Copyable>(novel: UUID, entity: String, in transaction: borrowing Transaction) throws(DomainError) -> EntityRecord? {
    let ref = EntityRecord.ref(novel: novel, entity: entity)
    let reading: RecordReading<EntityRecord>
    do throws(StoreError) {
      reading = try EntityRecord.read(ref, in: transaction)
    } catch {
      throw .store(error)
    }
    guard let found = try readable(reading, ref: ref), !found.isRemoved else { return nil }
    return found.record
  }

  // entity.service.ts:83: the reference pages by updated time, which a record does not carry; here the order is the entity key
  public static func list<Transaction: StateReading & ~Copyable>(
    novel: UUID, type: EntityType? = nil, origin: EntityOrigin? = nil, in transaction: borrowing Transaction
  ) throws(DomainError) -> [EntityRecord] {
    let listing: RecordListing<EntityRecord>
    do throws(StoreError) {
      listing = try EntityRecord.listing(novel: novel, in: transaction)
    } catch {
      throw .store(error)
    }
    return listing.live
      .filter { record in type.map { record.type == .known($0) } ?? true }
      .filter { record in origin.map { record.origin == .known($0) } ?? true }
      .sorted { JSText.codeUnitPrecedes($0.entity, $1.entity) }
  }

  private static func applying(_ details: EntityDetails, name: String, to record: EntityRecord) -> EntityRecord {
    var record = record
    record.name = name
    if case .set(let significance) = details.significance { record.significance = significance }
    if case .set(let status) = details.status { record.status = status }
    if case .set(let origin) = details.origin { record.origin = origin }
    if case .set(let notes) = details.notes { record.notes = notes }
    if case .set(let motivation) = details.motivation { record.motivation = motivation }
    if case .set(let body) = details.body { record.body = body }
    if case .set(let appearance) = details.appearance { record.appearance = appearance }
    return record
  }

  // Byte-exact, as the store compares values: an edit that only changes the normalisation form of a text is still written
  private static func difference(from existing: EntityRecord, to updated: EntityRecord) -> EntityEdit {
    var edit = EntityEdit()
    if !same(updated.name, existing.name) { edit.name = .set(updated.name) }
    if !same(updated.significance?.rawValue, existing.significance?.rawValue) { edit.significance = .set(updated.significance) }
    if !same(updated.status, existing.status) { edit.status = .set(updated.status) }
    if !same(updated.origin?.rawValue, existing.origin?.rawValue) { edit.origin = .set(updated.origin) }
    if !same(updated.notes, existing.notes) { edit.notes = .set(updated.notes) }
    if !same(updated.motivation, existing.motivation) { edit.motivation = .set(updated.motivation) }
    if !same(updated.body, existing.body) { edit.body = .set(updated.body) }
    if !same(updated.appearance, existing.appearance) { edit.appearance = .set(updated.appearance) }
    return edit
  }

  private static func same(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (nil, nil): true
    case (let left?, let right?): JSString(left) == JSString(right)
    default: false
    }
  }
}

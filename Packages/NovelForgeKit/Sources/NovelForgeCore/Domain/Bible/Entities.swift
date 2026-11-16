import Foundation
import ShadowCore
import ShadowStore

public struct EntityDetails: Sendable, Equatable {
  public var significance: EntitySignificance?
  public var status: String?
  public var origin: EntityOrigin?
  public var notes: String?
  public var motivation: String?
  public var body: String?
  public var appearance: String?

  public init(
    significance: EntitySignificance? = nil, status: String? = nil, origin: EntityOrigin? = nil, notes: String? = nil, motivation: String? = nil, body: String? = nil,
    appearance: String? = nil
  ) {
    self.significance = significance
    self.status = status
    self.origin = origin
    self.notes = notes
    self.motivation = motivation
    self.body = body
    self.appearance = appearance
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
    if let significance = details.significance { record.significance = .known(significance) }
    if let status = details.status { record.status = status }
    if let origin = details.origin { record.origin = .known(origin) }
    if let notes = details.notes { record.notes = notes }
    if let motivation = details.motivation { record.motivation = motivation }
    if let body = details.body { record.body = body }
    if let appearance = details.appearance { record.appearance = appearance }
    return record
  }

  private static func difference(from existing: EntityRecord, to updated: EntityRecord) -> EntityEdit {
    var edit = EntityEdit()
    if updated.name != existing.name { edit.name = .set(updated.name) }
    if updated.significance != existing.significance { edit.significance = .set(updated.significance) }
    if updated.status != existing.status { edit.status = .set(updated.status) }
    if updated.origin != existing.origin { edit.origin = .set(updated.origin) }
    if updated.notes != existing.notes { edit.notes = .set(updated.notes) }
    if updated.motivation != existing.motivation { edit.motivation = .set(updated.motivation) }
    if updated.body != existing.body { edit.body = .set(updated.body) }
    if updated.appearance != existing.appearance { edit.appearance = .set(updated.appearance) }
    return edit
  }
}

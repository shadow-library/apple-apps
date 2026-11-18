import Foundation
import ShadowCore
import ShadowStore

extension Library {
  // project.service.ts:240: the copy takes the source's settings, bible pages, entities and volumes; story fields, notes, plans, drafts and every derived or pipeline record start empty
  @discardableResult
  public static func clone(novel source: UUID, as copy: NovelCopy, id: UUID = UUID(), in transaction: inout WriteTransaction) throws(DomainError) -> UUID {
    try requireNonBlank(copy.name, field: "name")
    try requireWordTarget(copy.wordTarget)
    guard case .live(let original) = try transaction.presence(NovelForgeKey.novel(source), as: NovelRecord.self) else { throw .novelNotFound(source) }
    guard case .absent = try transaction.presence(NovelForgeKey.novel(id), as: NovelRecord.self) else { throw .novelExists(id) }
    try transaction.requireNoUnknownSectionPages(novel: source)
    let pages = try transaction.completeListing(PageRecord.self, novel: source)
    let entities = try transaction.completeListing(EntityRecord.self, novel: source)
    let volumes = try transaction.completeListing(VolumeRecord.self, novel: source)
    let record = NovelRecord(
      id: id, name: copy.name.jsTrim(), title: original.title, contentMode: copy.contentMode.map { .known($0) } ?? original.contentMode, costTier: original.costTier,
      wordTarget: copy.wordTarget ?? original.wordTarget, writingStyle: original.writingStyle, autoKeep: original.autoKeep)
    try transaction.create(record)
    for page in pages { try transaction.create(PageRecord(novel: id, section: page.section, slug: page.slug, content: page.content)) }
    for entity in entities { try transaction.create(relocated(entity, to: id)) }
    for volume in volumes {
      try transaction.create(
        VolumeRecord(novel: id, volume: volume.volume, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, body: volume.body, goalMet: volume.goalMet))
    }
    return id
  }

  private static func relocated(_ entity: EntityRecord, to novel: UUID) -> EntityRecord {
    EntityRecord(
      novel: novel, entity: entity.entity, type: entity.type, name: entity.name, attributes: entity.attributes, significance: entity.significance, status: entity.status,
      origin: entity.origin, notes: entity.notes, motivation: entity.motivation, body: entity.body, appearance: entity.appearance, wikiVisibility: entity.wikiVisibility,
      age: entity.age)
  }
}

extension WriteTransaction {
  // Listings skip a page of a section this version does not know; a copy would silently drop it
  fileprivate func requireNoUnknownSectionPages(novel: UUID) throws(DomainError) {
    let states: [(ref: EntityRef, state: EntityState)]
    do throws(StoreError) {
      states = try self.states(ofKind: PageRecord.kind.entityKind, scope: .vault)
    } catch {
      throw .store(error)
    }
    let skipped = states.filter { ref, state in
      guard case .unreadable(.unknownSection) = PageRecord.reading(state, of: ref), case .revisioned(let revisioned) = state else { return false }
      return PageRecord.owner(of: ref, in: FieldReader<DocumentField>(revisioned)) == novel
    }
    guard skipped.isEmpty else { throw .unreadableRecords(kind: PageRecord.kind.rawValue, count: skipped.count) }
  }

  fileprivate func completeListing<Record: KeyedRecord>(_: Record.Type, novel: UUID) throws(DomainError) -> [Record] {
    let listing: RecordListing<Record>
    do throws(StoreError) {
      listing = try Record.listing(novel: novel, in: self)
    } catch {
      throw .store(error)
    }
    guard listing.unreadable == 0 else { throw .unreadableRecords(kind: Record.kind.rawValue, count: listing.unreadable) }
    return listing.live
  }
}

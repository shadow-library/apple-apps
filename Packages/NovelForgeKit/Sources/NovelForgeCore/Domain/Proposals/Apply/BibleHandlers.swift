import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/apply/{bible-document,entity}.handler.ts; an undo over a tombstone keeps what the inverse does not name
enum BibleHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let novel = context.novel
    switch operation {
    case .bibleDocumentUpsert(let upsert): return try upsertDocument(upsert, novel: novel, in: &transaction)
    case .bibleDocumentRemove(let removal): return try removeDocument(section: removal.section, slug: removal.slug, novel: novel, in: &transaction)
    case .entityUpsert(let upsert): return try upsertEntity(upsert, novel: novel, in: &transaction)
    case .entityRemove(let removal): return try removeEntity(removal.entityKey, novel: novel, in: &transaction)
    default: throw .noHandler(operation.type)
    }
  }

  /// Writes back what an inverse captured, verbatim (proposal-revert.service.ts:148 applies it as an op).
  static func undo(_ inverse: OrderedJSONObject, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let restore: BibleRestore
    do throws(ApplyRefusal) {
      restore = try BibleRestore(inverse)
    } catch {
      throw .refused(error)
    }
    let novel = context.novel
    switch restore {
    case .document(let document): return try restoreDocument(document, novel: novel, in: &transaction)
    case .documentRemoval(let section, let slug): return try removeDocument(section: section, slug: slug, novel: novel, in: &transaction)
    case .entity(let entity): return try restoreEntity(entity, novel: novel, in: &transaction)
    case .entityRemoval(let key): return try removeEntity(key, novel: novel, in: &transaction)
    }
  }

  // bible-document.handler.ts:29: frontmatter and body as given, no title derived; on an existing page a field the op leaves out is kept (an undefined
  // column drops out of the upsert's set), on a new one it is empty; an unchanged page gets no revision (the upsert's setWhere)
  private static func upsertDocument(_ upsert: BibleDocumentUpsert, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let (section, slug) = (upsert.section, upsert.slug)
    guard !slug.isEmpty else { throw .refused(.notAllowed) }
    var frontmatter: [String: JSONValue]?
    if let given = upsert.frontmatter {
      guard let stored = storableObject(.object(given)) else { throw .refused(.unstorable(field: "frontmatter")) }
      frontmatter = stored
    }
    let presence = try pagePresence(section: section, slug: slug, novel: novel, in: transaction)
    guard case .live(let existing) = presence else {
      try write(PageContent(frontmatter: frontmatter, body: upsert.body), section: section, slug: slug, over: presence, novel: novel, in: &transaction)
      return HandlerOutcome(inverse: DocumentRestore.removal(section: section, slug: slug))
    }
    var content = existing.content
    if upsert.frontmatter != nil { content.frontmatter = frontmatter }
    if let body = upsert.body { content.body = body }
    try write(content, section: section, slug: slug, over: presence, novel: novel, in: &transaction)
    return HandlerOutcome(inverse: DocumentRestore(existing.content, section: section, slug: slug).json)
  }

  private static func restoreDocument(_ restore: DocumentRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let (section, slug) = (restore.section, restore.slug)
    let presence = try pagePresence(section: section, slug: slug, novel: novel, in: transaction)
    var content = PageContent()
    var inverse = DocumentRestore.removal(section: section, slug: slug)
    switch presence {
    case .live(let existing):
      content = existing.content
      inverse = DocumentRestore(existing.content, section: section, slug: slug).json
    case .removed(let tombstone): content = tombstone.content
    case .absent: break
    }
    content.frontmatter = restore.frontmatter
    content.body = restore.body
    try write(content, section: section, slug: slug, over: presence, novel: novel, in: &transaction)
    return HandlerOutcome(inverse: inverse)
  }

  // bible-document.handler.ts:55: a page that is not there is DOC_001; the record is marked removed and keeps its versions
  private static func removeDocument(section: BiblePageSection, slug: String, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError)
    -> HandlerOutcome
  {
    guard !slug.isEmpty else { throw .refused(.notAllowed) }
    guard case .live(let existing) = try pagePresence(section: section, slug: slug, novel: novel, in: transaction) else {
      throw .domain(.documentNotFound(section: section.rawValue, slug: slug))
    }
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    try handlerDomain(documentArtifact(section, slug), ref) { () throws(DomainError) in try Pages.remove(novel: novel, section: section, slug: slug, in: &transaction) }
    return HandlerOutcome(inverse: DocumentRestore(existing.content, section: section, slug: slug).json)
  }

  // entity.handler.ts:28: a new entity needs a name and is `generated`; an existing one takes the op's type and keeps what the op leaves out; an empty
  // key or a blank name is refused, as the author's path refuses them (Entities.create)
  private static func upsertEntity(_ upsert: EntityUpsert, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = upsert.entityKey
    guard !key.isEmpty else { throw .refused(.notAllowed) }
    if let name = upsert.name, name.jsTrim().isEmpty { throw .refused(.notAllowed) }
    let presence = try entityPresence(key, novel: novel, in: transaction)
    guard case .live(let existing) = presence else {
      guard let name = upsert.name else { throw .refused(.notAllowed) }
      let record = EntityRecord(
        novel: novel, entity: key, type: .known(upsert.type), name: name, status: upsert.status, origin: .known(.generated), notes: upsert.notes,
        motivation: upsert.motivation, body: upsert.body)
      try write(record, over: presence, novel: novel, in: &transaction)
      return HandlerOutcome(inverse: EntityRestore.removal(key))
    }
    var updated = existing
    updated.type = .known(upsert.type)
    updated.name = upsert.name ?? existing.name
    updated.status = upsert.status ?? existing.status
    updated.motivation = upsert.motivation ?? existing.motivation
    updated.notes = upsert.notes ?? existing.notes
    updated.body = upsert.body ?? existing.body
    try write(updated, over: presence, novel: novel, in: &transaction)
    return HandlerOutcome(inverse: EntityRestore(existing, key: key).json)
  }

  private static func restoreEntity(_ restore: EntityRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = restore.entity
    let presence = try entityPresence(key, novel: novel, in: transaction)
    var record = EntityRecord(novel: novel, entity: key, type: restore.type, name: restore.name, origin: .known(.generated))
    var inverse = EntityRestore.removal(key)
    switch presence {
    case .live(let existing):
      record = existing
      inverse = EntityRestore(existing, key: key).json
    case .removed(let tombstone): record = tombstone
    case .absent: break
    }
    record.type = restore.type
    record.name = restore.name
    record.status = restore.status
    record.motivation = restore.motivation
    record.notes = restore.notes
    record.body = restore.body
    try write(record, over: presence, novel: novel, in: &transaction)
    return HandlerOutcome(inverse: inverse)
  }

  // entity.handler.ts:52: an entity that is not there is RFN_004; the record is marked removed and what depends on it is hidden by derivation
  private static func removeEntity(_ key: String, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    guard !key.isEmpty else { throw .refused(.notAllowed) }
    guard case .live(let existing) = try entityPresence(key, novel: novel, in: transaction) else { throw .refused(.notAllowed) }
    let ref = EntityRecord.ref(novel: novel, entity: key)
    try handlerDomain("entity:\(key)", ref) { () throws(DomainError) in try Entities.remove(novel: novel, entity: key, in: &transaction) }
    return HandlerOutcome(inverse: EntityRestore(existing, key: key).json)
  }

  private static func pagePresence(section: BiblePageSection, slug: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError)
    -> Presence<PageRecord>
  {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    return try handlerDomain(documentArtifact(section, slug), ref) { () throws(DomainError) in
      try transaction.requireNovel(novel)
      return try transaction.presence(ref, as: PageRecord.self)
    }
  }

  private static func entityPresence(_ key: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Presence<EntityRecord> {
    let ref = EntityRecord.ref(novel: novel, entity: key)
    return try handlerDomain("entity:\(key)", ref) { () throws(DomainError) in
      try transaction.requireNovel(novel)
      return try transaction.presence(ref, as: EntityRecord.self)
    }
  }

  /// One write of `content` as the page's head: a revision only when it differs from the head the record holds (a restored tombstone's included).
  private static func write(
    _ content: PageContent, section: BiblePageSection, slug: String, over presence: Presence<PageRecord>, novel: UUID, in transaction: inout WriteTransaction
  ) throws(ApplyError) {
    try handlerStore { () throws(StoreError) in
      switch presence {
      case .live(let existing):
        guard !sameRevision(content, existing.content) else { return }
        _ = try PageRecord.revise(novel: novel, section: section, slug: slug, content, in: &transaction)
      case .removed(let tombstone):
        _ = try tombstone.restore(in: &transaction)
        guard !sameRevision(content, tombstone.content) else { return }
        _ = try PageRecord.revise(novel: novel, section: section, slug: slug, content, in: &transaction)
      case .absent:
        _ = try PageRecord(novel: novel, section: section, slug: slug, content: content).create(in: &transaction)
      }
    }
  }

  /// A live entity gets the fields that differ, byte for byte; a removed or absent one is written whole.
  private static func write(_ record: EntityRecord, over presence: Presence<EntityRecord>, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) {
    try handlerStore { () throws(StoreError) in
      switch presence {
      case .live(let existing):
        let edit = difference(from: existing, to: record)
        guard !edit.fields.members.isEmpty else { return }
        _ = try EntityRecord.edit(novel: novel, entity: record.entity, edit, in: &transaction)
      case .removed: _ = try record.restore(in: &transaction)
      case .absent: _ = try record.create(in: &transaction)
      }
    }
  }

  private static func difference(from existing: EntityRecord, to updated: EntityRecord) -> EntityEdit {
    var edit = EntityEdit()
    if !updated.type.rawValue.utf8.elementsEqual(existing.type.rawValue.utf8) { edit.type = .set(updated.type) }
    if !sameText(updated.name, existing.name) { edit.name = .set(updated.name) }
    if !sameText(updated.status, existing.status) { edit.status = .set(updated.status) }
    if !sameText(updated.motivation, existing.motivation) { edit.motivation = .set(updated.motivation) }
    if !sameText(updated.notes, existing.notes) { edit.notes = .set(updated.notes) }
    if !sameText(updated.body, existing.body) { edit.body = .set(updated.body) }
    return edit
  }

  private static func documentArtifact(_ section: BiblePageSection, _ slug: String) -> String {
    "doc:\(section.rawValue)/\(slug)"
  }
}

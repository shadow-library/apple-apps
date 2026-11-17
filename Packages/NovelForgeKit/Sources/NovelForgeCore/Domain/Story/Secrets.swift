import Foundation
import ShadowCore
import ShadowStore

public struct SecretChanges: Sendable, Equatable {
  public var subjects: FieldChange<[String]?> = .keep
  public var constraintNote: FieldChange<String?> = .keep
  public var writerNote: FieldChange<String?> = .keep
  public var terms: FieldChange<[String]?> = .keep
  public var allowedClues: FieldChange<[String]?> = .keep
  public var revealChapter: FieldChange<Int?> = .keep
  public var unlock: FieldChange<JSONValue?> = .keep

  public init(
    subjects: FieldChange<[String]?> = .keep, constraintNote: FieldChange<String?> = .keep, writerNote: FieldChange<String?> = .keep, terms: FieldChange<[String]?> = .keep,
    allowedClues: FieldChange<[String]?> = .keep, revealChapter: FieldChange<Int?> = .keep, unlock: FieldChange<JSONValue?> = .keep
  ) {
    self.subjects = subjects
    self.constraintNote = constraintNote
    self.writerNote = writerNote
    self.terms = terms
    self.allowedClues = allowedClues
    self.revealChapter = revealChapter
    self.unlock = unlock
  }
}

// apps/novel-forge-server/src/modules/bible/fact/fact.service.ts; plan state is derived
public enum Secrets {
  // fact.service.ts:61: creates the secret or merges the changes into it; an omitted field keeps its value, a nil clears it
  public static func upsert(novel: UUID, secret: String, text: String, _ changes: SecretChanges = SecretChanges(), in transaction: inout WriteTransaction) throws(DomainError) {
    try requireKey(secret, field: "factKey")
    guard !text.isEmpty else { throw .blank(field: "text") }
    if case .set(let unlock?) = changes.unlock {
      let errors = validateUnlockCondition(OrderedJSON(unlock))
      guard errors.isEmpty else { throw .unlockMalformed(errors.joined(separator: "; ")) }
    }
    if case .set(let chapter?) = changes.revealChapter { try requireAtLeast(chapter, 1, field: "revealChapter") }
    try transaction.requireNovel(novel)
    let ref = SecretRecord.ref(novel: novel, secret: secret)
    switch try transaction.presence(ref, as: SecretRecord.self) {
    case .live(let existing):
      let updated = applying(changes, text: text, to: existing)
      try requireNoGiveaways(before: existing, after: updated)
      try transaction.edit(SecretRecord.self, ref, difference(from: existing, to: updated).fields)
    case .removed, .absent:
      let created = applying(changes, text: text, to: SecretRecord(novel: novel, secret: secret, text: text))
      try requireNoGiveaways(before: nil, after: created)
      try transaction.create(created)
    }
  }

  // fact.service.ts:85 over reveal-term.ts:39: changed clues may not name a give-away term of their fact; a new fact has every clue judged
  static func requireNoGiveaways(before: SecretRecord?, after: SecretRecord) throws(DomainError) {
    let prior = before.map { ClueTermFields(allowedClues: $0.cluesAndTerms?.clues, terms: $0.cluesAndTerms?.terms) }
    let giveaways: [String]
    do throws(DisclosureError) {
      giveaways = try changedCluesNamingTerms(before: prior, after: ClueTermFields(allowedClues: after.cluesAndTerms?.clues, terms: after.cluesAndTerms?.terms))
    } catch {
      throw .cluesUncheckable(error.errorDescription ?? error.code)
    }
    guard giveaways.isEmpty else { throw .clueNamesTerm(giveaways.joined(separator: "; ")) }
  }

  // fact.service.ts:102: the knowledge rows of a removed secret are hidden by derivation, never deleted
  public static func remove(novel: UUID, secret: String, in transaction: inout WriteTransaction) throws(DomainError) {
    try transaction.requireNovel(novel)
    let ref = SecretRecord.ref(novel: novel, secret: secret)
    guard case .live = try transaction.presence(ref, as: SecretRecord.self) else { throw .secretNotFound(secret) }
    try transaction.remove(SecretRecord.self, ref)
  }

  public static func restore(novel: UUID, secret: String, in transaction: inout WriteTransaction) throws(DomainError) {
    switch try transaction.presence(SecretRecord.ref(novel: novel, secret: secret), as: SecretRecord.self) {
    case .removed(let record): try transaction.restore(record)
    case .live: return
    case .absent: throw .secretNotFound(secret)
    }
  }

  // fact.service.ts:73
  private static func applying(_ changes: SecretChanges, text: String, to record: SecretRecord) -> SecretRecord {
    var record = record
    record.text = text
    if case .set(let subjects) = changes.subjects { record.subjects = subjects }
    if case .set(let note) = changes.constraintNote { record.constraintNote = note }
    if case .set(let note) = changes.writerNote { record.writerNote = trimmedOrNil(note) }
    if case .set(let revealChapter) = changes.revealChapter { record.revealChapter = revealChapter }
    if case .set(let unlock) = changes.unlock { record.unlock = unlock }
    var cluesAndTerms = record.cluesAndTerms ?? CluesAndTerms()
    if case .set(let terms) = changes.terms { cluesAndTerms.terms = terms }
    if case .set(let clues) = changes.allowedClues { cluesAndTerms.clues = clues.map(normalizeStringList) }
    record.cluesAndTerms = cluesAndTerms.clues == nil && cluesAndTerms.terms == nil && cluesAndTerms.unrecognised.isEmpty ? nil : cluesAndTerms
    return record
  }

  private static func difference(from existing: SecretRecord, to updated: SecretRecord) -> SecretEdit {
    var edit = SecretEdit()
    if updated.text != existing.text { edit.text = .set(updated.text) }
    if updated.subjects != existing.subjects { edit.subjects = .set(updated.subjects) }
    if updated.constraintNote != existing.constraintNote { edit.constraintNote = .set(updated.constraintNote) }
    if updated.writerNote != existing.writerNote { edit.writerNote = .set(updated.writerNote) }
    if updated.cluesAndTerms != existing.cluesAndTerms { edit.cluesAndTerms = .set(updated.cluesAndTerms) }
    if updated.revealChapter != existing.revealChapter { edit.revealChapter = .set(updated.revealChapter) }
    if updated.unlock != existing.unlock { edit.unlock = .set(updated.unlock) }
    return edit
  }
}

// fact.service.ts:119,140: only the author's manual reveals are records; a retraction is a removal
public enum ManualReveals {
  public static func reveal(novel: UUID, secret: String, entity: String, chapter: Int, note: String? = nil, in transaction: inout WriteTransaction) throws(DomainError) {
    try requireAtLeast(chapter, 1, field: "chapter")
    try requireTargets(novel: novel, secret: secret, entity: entity, in: transaction)
    let record = CharacterKnowledgeRecord(novel: novel, fact: secret, entity: entity, reveal: ManualReveal(chapter: chapter, note: note))
    if case .live(let existing) = try transaction.presence(record.ref, as: CharacterKnowledgeRecord.self), existing == record { return }
    try transaction.create(record)
  }

  public static func retract(novel: UUID, secret: String, entity: String, in transaction: inout WriteTransaction) throws(DomainError) {
    try requireTargets(novel: novel, secret: secret, entity: entity, in: transaction)
    let ref = CharacterKnowledgeRecord.ref(novel: novel, fact: secret, entity: entity)
    guard case .live = try transaction.presence(ref, as: CharacterKnowledgeRecord.self) else { return }
    try transaction.remove(CharacterKnowledgeRecord.self, ref)
  }

  private static func requireTargets(novel: UUID, secret: String, entity: String, in transaction: borrowing WriteTransaction) throws(DomainError) {
    try transaction.requireNovel(novel)
    guard case .live = try transaction.presence(SecretRecord.ref(novel: novel, secret: secret), as: SecretRecord.self) else { throw .secretNotFound(secret) }
    guard case .live = try transaction.presence(EntityRecord.ref(novel: novel, entity: entity), as: EntityRecord.self) else { throw .entityUnknown(entity) }
  }
}

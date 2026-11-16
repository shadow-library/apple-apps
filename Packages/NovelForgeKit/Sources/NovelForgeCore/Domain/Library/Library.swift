import Foundation
import ShadowCore
import ShadowStore

private let titleLimitOnCreate = 255
private let titleLimitOnEdit = 500
private let notesCharacterLimit = 100_000
private let notesWordLimit = 10_000
private let wordTargetFloor = 500
private let wordTargetCeiling = 6000

// apps/novel-forge-server/src/modules/project/project/project.service.ts, modules/new-novel/new-novel.service.ts, modules/notes/notes-store.service.ts
public enum Library {
  // new-novel.service.ts:41: the title is the name; the author's notes are written with the novel. The chat session of the reference belongs to the chat phase
  @discardableResult
  public static func create(_ input: NewNovel, id: UUID = UUID(), in transaction: inout WriteTransaction) throws(DomainError) -> UUID {
    try requireAtMost(input.title, titleLimitOnCreate, field: "title")
    let title = input.title.jsTrim()
    try requireNonBlank(title, field: "title")
    try requireAtMost(input.notes ?? "", notesCharacterLimit, field: "notes")
    try requireWordTarget(input.wordTarget)
    let notes = try validNotes(input.notes ?? "")
    guard case .absent = try transaction.presence(NovelForgeKey.novel(id), as: NovelRecord.self) else { throw .novelExists(id) }
    let record = NovelRecord(
      id: id, name: title, title: title, contentMode: .known(input.contentMode), costTier: .known(input.costTier), wordTarget: input.wordTarget,
      writingStyle: trimmedOrNil(input.writingStyle))
    try transaction.create(record)
    if !notes.isEmpty { try transaction.create(AuthorNotesRecord(novel: id, content: AuthorNotesContent(text: notes))) }
    return id
  }

  // project.service.ts:204: story fields and the title are trimmed and a blank clears them; the word target is checked as on create
  public static func edit(novel: UUID, _ changes: NovelChanges, in transaction: inout WriteTransaction) throws(DomainError) {
    guard !changes.isEmpty else { throw .noChanges }
    if case .set(let title?) = changes.title { try requireAtMost(title, titleLimitOnEdit, field: "title") }
    if case .set(let target) = changes.wordTarget { try requireWordTarget(target) }
    try transaction.requireNovel(novel)
    var edit = NovelEdit()
    edit.title = changes.title.map(trimmedOrNil)
    edit.contentMode = changes.contentMode
    edit.costTier = changes.costTier
    edit.wordTarget = changes.wordTarget
    edit.brief = changes.brief
    edit.theme = changes.theme.map(trimmedOrNil)
    edit.endingQuestion = changes.endingQuestion.map(trimmedOrNil)
    edit.ending = changes.ending.map(trimmedOrNil)
    edit.readerPromise = changes.readerPromise.map(trimmedOrNil)
    edit.protagonist = changes.protagonist.map(trimmedOrNil)
    edit.opposition = changes.opposition.map(trimmedOrNil)
    edit.writingStyle = changes.writingStyle.map(trimmedOrNil)
    try transaction.edit(NovelRecord.self, NovelForgeKey.novel(novel), edit.fields)
  }

  public static func archive(novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) {
    try setArchived(true, novel: novel, in: &transaction)
  }

  public static func restore(novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) {
    try setArchived(false, novel: novel, in: &transaction)
  }

  // notes-store.service.ts:81: trimmed, held to 10,000 words; blank notes clear them. Identical notes write no revision
  public static func replaceNotes(novel: UUID, text: String, in transaction: inout WriteTransaction) throws(DomainError) {
    try requireAtMost(text, notesCharacterLimit, field: "notes")
    let notes = try validNotes(text)
    try transaction.requireNovel(novel)
    switch try transaction.presence(AuthorNotesRecord.ref(novel: novel), as: AuthorNotesRecord.self) {
    case .live(let existing):
      guard existing.content.text != notes else { return }
      var content = existing.content
      content.text = notes
      try revise(content, novel: novel, in: &transaction)
    case .removed, .absent:
      guard !notes.isEmpty else { return }
      try transaction.create(AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: notes)))
    }
  }

  // notes-store.service.ts:75
  public static func notes<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(DomainError) -> String {
    let reading: RecordReading<AuthorNotesRecord>
    do throws(StoreError) {
      reading = try AuthorNotesRecord.read(novel: novel, in: transaction)
    } catch {
      throw .store(error)
    }
    return try readable(reading, ref: AuthorNotesRecord.ref(novel: novel))?.record.content.text ?? ""
  }

  private static func setArchived(_ archived: Bool, novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) {
    guard case .live(let record) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self) else { throw .novelNotFound(novel) }
    guard record.archived != archived else { return }
    var edit = NovelEdit()
    edit.archived = .set(archived)
    try transaction.edit(NovelRecord.self, record.ref, edit.fields)
  }

  private static func revise(_ content: AuthorNotesContent, novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) {
    do throws(StoreError) {
      _ = try AuthorNotesRecord.revise(novel: novel, content, in: &transaction)
    } catch {
      throw .store(error)
    }
  }

  private static func validNotes(_ text: String) throws(DomainError) -> String {
    let notes = text.jsTrim()
    let words = ProseMetrics.countWords(notes)
    guard words <= notesWordLimit else { throw .notesTooLong(words: words, maximum: notesWordLimit) }
    return notes
  }

  // project.dto.ts:10: the bounds belong to each field; project.service.ts:86 only the relation of the two
  static func requireWordTarget(_ target: WordTarget?) throws(DomainError) {
    guard let target else { return }
    for (field, value) in [("wordTarget.min", target.min), ("wordTarget.max", target.max)] {
      try requireAtLeast(value, wordTargetFloor, field: field)
      guard value <= wordTargetCeiling else { throw .aboveMaximum(field: field, maximum: wordTargetCeiling) }
    }
    guard target.max > target.min else { throw .wordTargetInverted }
  }

  static func trimmedOrNil(_ text: String?) -> String? {
    guard let trimmed = text?.jsTrim(), !trimmed.isEmpty else { return nil }
    return trimmed
  }
}

extension FieldChange {
  fileprivate func map<Other: JSONWritable & Equatable>(_ transform: (Value) -> Other) -> FieldChange<Other> {
    guard case .set(let value) = self else { return .keep }
    return .set(transform(value))
  }
}

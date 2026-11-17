import Foundation
import ShadowCore
import ShadowStore

/// The volumes, milestones and facts a plan's reveal rule reads. The plan world is derived after commit, so each write returns the overlay edit of the record
/// as written (apply-rules.ts:46 judges the change set as it leaves them).
enum StoryPlanState {
  // volume.handler.ts:20: the state moves only through action.advance_volume, and a new volume starts not reached. A new volume without an ordinal is placed
  // after the others (Volumes.create) rather than at the reference's 0: the active volume is derived from the order, and 0 would take it over, where the
  // reference's stored state leaves it in place
  static func upsertVolume(_ upsert: VolumeUpsert, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = upsert.volumeKey
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(VolumeRecord.ref(novel: novel, volume: key), as: VolumeRecord.self) }
    guard case .live(let existing) = presence else {
      if upsert.ordinal == nil { try requireStoryReadable(VolumeRecord.self, novel: novel, in: transaction) }
      try storyDomain { () throws(DomainError) in
        try Volumes.create(novel: novel, volume: key, ordinal: upsert.ordinal, title: upsert.title, objective: upsert.objective, body: upsert.body, in: &transaction)
      }
      return HandlerOutcome(inverse: StoryRestore.volumeRemoval(key).json, planEdits: [try writtenVolume(key, novel: novel, in: transaction)])
    }
    var changes = VolumeChanges()
    if let ordinal = upsert.ordinal { changes.ordinal = .set(ordinal) }
    if let title = upsert.title { changes.title = .set(title) }
    if let objective = upsert.objective { changes.objective = .set(objective) }
    if let body = upsert.body { changes.body = .set(body) }
    try storyDomain { () throws(DomainError) in try Volumes.edit(novel: novel, volume: key, changes, in: &transaction) }
    return HandlerOutcome(inverse: VolumeRestore(existing, key: key).json, planEdits: [.volume(storyKey(key), ordinal: upsert.ordinal ?? existing.ordinal)])
  }

  /// A removed volume comes back as it was, its met goal included, so the active volume does not move; every case is one write of the captured content.
  static func restoreVolume(_ restore: VolumeRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = restore.volume
    let ref = VolumeRecord.ref(novel: novel, volume: key)
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(ref, as: VolumeRecord.self) }
    let edits: [PlanOverlay.Edit] = [.volume(storyKey(key), ordinal: restore.ordinal)]
    switch presence {
    case .live(let existing):
      var edit = VolumeEdit()
      edit.ordinal = .set(restore.ordinal)
      edit.title = .set(restore.title)
      edit.objective = .set(restore.objective)
      edit.body = .set(restore.body)
      try storyDomain { () throws(DomainError) in try transaction.edit(VolumeRecord.self, ref, edit.fields) }
      return HandlerOutcome(inverse: VolumeRestore(existing, key: key).json, planEdits: edits)
    case .removed(var removed):
      removed.ordinal = restore.ordinal
      removed.title = restore.title
      removed.objective = restore.objective
      removed.body = restore.body
      try storyDomain { () throws(DomainError) in try transaction.restore(removed) }
    case .absent:
      try storyDomain { () throws(DomainError) in try transaction.requireNovel(novel) }
      let record = VolumeRecord(novel: novel, volume: key, ordinal: restore.ordinal, title: restore.title, objective: restore.objective, body: restore.body)
      try storyDomain { () throws(DomainError) in try transaction.create(record) }
    }
    return HandlerOutcome(inverse: StoryRestore.volumeRemoval(key).json, planEdits: edits)
  }

  // volume.handler.ts:48: refused while a chapter plan names the volume, including one this device cannot read
  static func removeVolume(_ key: String, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(VolumeRecord.ref(novel: novel, volume: key), as: VolumeRecord.self) }
    guard case .live(let existing) = presence else { throw .domain(.volumeNotFound(key)) }
    try requireStoryReadable(ChapterPlanRecord.self, novel: novel, in: transaction)
    try storyDomain { () throws(DomainError) in try Volumes.remove(novel: novel, volume: key, in: &transaction) }
    return HandlerOutcome(inverse: VolumeRestore(existing, key: key).json, planEdits: [.volumeRemoved(storyKey(key))])
  }

  // milestone.handler.ts:34: a new milestone needs a label; a subject is checked only when it changes; a blank label keeps the one it has
  static func upsertMilestone(_ upsert: MilestoneUpsert, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = upsert.milestoneKey
    let presence = try storyDomain { () throws(DomainError) in
      try transaction.presence(MilestoneRecord.ref(novel: novel, milestone: key), as: MilestoneRecord.self)
    }
    let subject: String?? =
      switch upsert.subjectEntityKey {
      case .omitted: nil
      case .null: .some(nil)
      case .set(let named): .some(trimmedOrNil(named))
      }
    guard case .live(let existing) = presence else {
      guard let label = trimmedOrNil(upsert.label) else { throw .refused(.notAllowed) }
      let kind = StoredEnum.known(upsert.kind ?? .custom)
      try storyDomain { () throws(DomainError) in
        try Milestones.create(novel: novel, milestone: key, label: label, subject: subject ?? nil, kind: kind, in: &transaction)
      }
      return HandlerOutcome(inverse: StoryRestore.milestoneRemoval(key).json, planEdits: [.milestone(storyKey(key))])
    }
    var changes = MilestoneChanges()
    changes.label = trimmedOrNil(upsert.label)
    if let subject, !sameText(subject, existing.subject) { changes.subject = .set(subject) }
    changes.kind = upsert.kind.map(StoredEnum.known)
    if !changes.isEmpty { try storyDomain { () throws(DomainError) in try Milestones.edit(novel: novel, milestone: key, changes, in: &transaction) } }
    return HandlerOutcome(inverse: MilestoneRestore(existing, key: key).json, planEdits: [.milestone(storyKey(key))])
  }

  // milestone.handler.ts:39: a restore writes its subject back unchecked, as the milestone had it
  static func restoreMilestone(_ restore: MilestoneRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = restore.milestone
    let ref = MilestoneRecord.ref(novel: novel, milestone: key)
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(ref, as: MilestoneRecord.self) }
    let record = MilestoneRecord(novel: novel, milestone: key, label: restore.label, subject: restore.subject, kind: restore.kind)
    switch presence {
    case .live(let existing):
      var edit = MilestoneEdit()
      edit.label = .set(restore.label)
      edit.subject = .set(restore.subject)
      edit.kind = .set(restore.kind)
      try storyDomain { () throws(DomainError) in try transaction.edit(MilestoneRecord.self, ref, edit.fields) }
      return HandlerOutcome(inverse: MilestoneRestore(existing, key: key).json, planEdits: [.milestone(storyKey(key))])
    case .removed: try storyDomain { () throws(DomainError) in try transaction.restore(record) }
    case .absent:
      try storyDomain { () throws(DomainError) in try transaction.requireNovel(novel) }
      try storyDomain { () throws(DomainError) in try transaction.create(record) }
    }
    return HandlerOutcome(inverse: StoryRestore.milestoneRemoval(key).json, planEdits: [.milestone(storyKey(key))])
  }

  // milestone.handler.ts:63 over plan-state.ts:152: refused while a plan claims it or a fact's unlock names it, including ones this device cannot read; a
  // promise's payoff naming it does not hold it back
  static func removeMilestone(_ key: String, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    try requireStoryReadable(ChapterPlanRecord.self, novel: novel, in: transaction)
    try requireStoryReadable(SecretRecord.self, novel: novel, in: transaction)
    let references = try storyDomain { () throws(DomainError) in try Milestones.references(to: storyKey(key), novel: novel, in: transaction) }
    guard references.isEmpty else { throw .domain(.milestoneReferenced(milestone: storyKey(key), references: references)) }
    let presence = try storyDomain { () throws(DomainError) in
      try transaction.presence(MilestoneRecord.ref(novel: novel, milestone: key), as: MilestoneRecord.self)
    }
    guard case .live(let existing) = presence else { throw .domain(.milestoneNotFound(key)) }
    try storyDomain { () throws(DomainError) in try Milestones.remove(novel: novel, milestone: key, in: &transaction) }
    return HandlerOutcome(inverse: MilestoneRestore(existing, key: key).json, planEdits: [.milestoneRemoved(storyKey(key))])
  }

  // fact.handler.ts:33 through fact.service.ts:61's merge, which refuses changed clues that name a give-away term (FCT_006): a new fact needs a body
  static func upsertFact(_ upsert: FactUpsert, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = upsert.factKey
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(SecretRecord.ref(novel: novel, secret: key), as: SecretRecord.self) }
    var existing: SecretRecord?
    if case .live(let record) = presence { existing = record }
    guard let text = upsert.body ?? existing?.text else { throw .refused(.notAllowed) }
    let changes = SecretChanges(
      subjects: upsert.subjects.map { .set($0) } ?? .keep, constraintNote: upsert.constraintNote.map { .set($0) } ?? .keep,
      writerNote: upsert.writerNote.map { .set($0) } ?? .keep, terms: upsert.terms.map { .set($0) } ?? .keep, allowedClues: change(upsert.allowedClues),
      revealChapter: change(upsert.revealChapter), unlock: change(upsert.unlock) { storyJSONValue(unlockJSON($0)) })
    try storyDomain { () throws(DomainError) in try Secrets.upsert(novel: novel, secret: key, text: text, changes, in: &transaction) }
    let inverse = existing.map { StoryRestore.fact(FactRestore($0, key: key)) } ?? .factRemoval(key)
    return HandlerOutcome(inverse: inverse.json, planEdits: [try written(key, novel: novel, in: transaction)])
  }

  static func restoreFact(_ restore: FactRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let key = restore.fact
    let ref = SecretRecord.ref(novel: novel, secret: key)
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(ref, as: SecretRecord.self) }
    var current: SecretRecord?
    if case .live(let record) = presence { current = record }
    let inverse = current.map { StoryRestore.fact(FactRestore($0, key: key)) } ?? .factRemoval(key)
    switch presence {
    case .live(let record):
      try storyDomain { () throws(DomainError) in try Secrets.requireNoGiveaways(before: record, after: restoring(record, restore)) }
      try storyDomain { () throws(DomainError) in try transaction.edit(SecretRecord.self, ref, restored(record, restore).fields) }
    case .removed(let record):
      try storyDomain { () throws(DomainError) in try Secrets.requireNoGiveaways(before: nil, after: restoring(record, restore)) }
      try storyDomain { () throws(DomainError) in try transaction.restore(restoring(record, restore)) }
    case .absent:
      try storyDomain { () throws(DomainError) in try transaction.requireNovel(novel) }
      let created = restoring(SecretRecord(novel: novel, secret: key, text: restore.text), restore)
      try storyDomain { () throws(DomainError) in try Secrets.requireNoGiveaways(before: nil, after: created) }
      try storyDomain { () throws(DomainError) in try transaction.create(created) }
    }
    return HandlerOutcome(inverse: inverse.json, planEdits: [try written(key, novel: novel, in: transaction)])
  }

  // fact.handler.ts:62. FCT_003 is not ported: it guards a delete that cascades the knowledge ledger the inverse cannot rebuild, and here a removal hides that
  // knowledge by derivation and the inverse brings it back
  static func removeFact(_ key: String, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let presence = try storyDomain { () throws(DomainError) in try transaction.presence(SecretRecord.ref(novel: novel, secret: key), as: SecretRecord.self) }
    guard case .live(let existing) = presence else { throw .domain(.secretNotFound(key)) }
    try storyDomain { () throws(DomainError) in try Secrets.remove(novel: novel, secret: key, in: &transaction) }
    return HandlerOutcome(inverse: FactRestore(existing, key: key).json, planEdits: [.factRemoved(storyKey(key))])
  }

  private static func writtenVolume(_ key: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> PlanOverlay.Edit {
    let reading = try storyStore { () throws(StoreError) in try VolumeRecord.read(novel: novel, volume: key, in: transaction) }
    guard case .readable(let entry) = reading, !entry.isRemoved else { throw .unreadable(ref: "volume:\(key)") }
    return .volume(entry.record.volume, ordinal: entry.record.ordinal)
  }

  /// The fact as the plan world reads it once written; the reveal rule judges plans against facts, never against what a chapter disclosed.
  private static func written(_ key: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> PlanOverlay.Edit {
    let reading = try storyStore { () throws(StoreError) in try SecretRecord.read(novel: novel, secret: key, in: transaction) }
    guard case .readable(let entry) = reading, !entry.isRemoved else { throw .unreadable(ref: "fact:\(key)") }
    return .fact(DisclosureFact(secret: entry.record, disclosedInChapter: nil))
  }

  private static func restored(_ record: SecretRecord, _ restore: FactRestore) -> SecretEdit {
    let target = restoring(record, restore)
    var edit = SecretEdit()
    edit.text = .set(target.text)
    edit.subjects = .set(target.subjects)
    edit.constraintNote = .set(target.constraintNote)
    edit.writerNote = .set(target.writerNote)
    edit.cluesAndTerms = .set(target.cluesAndTerms)
    edit.revealChapter = .set(target.revealChapter)
    edit.unlock = .set(target.unlock)
    return edit
  }

  private static func restoring(_ record: SecretRecord, _ restore: FactRestore) -> SecretRecord {
    var record = record
    record.text = restore.text
    record.subjects = restore.subjects
    record.constraintNote = restore.constraintNote
    record.writerNote = restore.writerNote
    record.revealChapter = restore.revealChapter
    record.unlock = restore.unlock
    var cluesAndTerms = record.cluesAndTerms ?? CluesAndTerms()
    cluesAndTerms.clues = restore.allowedClues
    cluesAndTerms.terms = restore.terms
    record.cluesAndTerms = cluesAndTerms.clues == nil && cluesAndTerms.terms == nil && cluesAndTerms.unrecognised.isEmpty ? nil : cluesAndTerms
    return record
  }

  private static func change<Value: Sendable & Equatable>(_ value: OpValue<Value>) -> FieldChange<Value?> where Value: JSONWritable {
    change(value) { $0 }
  }

  private static func change<Value: Sendable & Equatable, Stored: JSONWritable & Equatable>(_ value: OpValue<Value>, _ convert: (Value) -> Stored?) -> FieldChange<
    Stored?
  > {
    switch value {
    case .omitted: .keep
    case .null: .set(nil)
    case .set(let value): .set(convert(value))
    }
  }
}

private func storyKey(_ key: String) -> String {
  key.precomposedStringWithCanonicalMapping
}

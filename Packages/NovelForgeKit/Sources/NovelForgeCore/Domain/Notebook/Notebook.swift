import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts; the guards read the local state, `NotebookResolution` carries the merge across devices
public enum Notebook {
  private static let statementLimit = 4000
  private static let whyLimit = 4000
  private static let writerLineLimit = 1000
  private static let alternativesLimit = 20
  private static let stepKeyLimit = 60
  private static let ideaIdLimit = 64
  private static let authorKinds: [LedgerEntryKind] = [.direction, .rejected, .backlog]
  private static let supersedeKinds: [LedgerEntryKind] = [.decision, .direction, .rejected, .backlog]

  // ledger.service.ts:104
  @discardableResult
  public static func record(_ entries: [NewNotebookEntry], novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> [NotebookEntryRecord] {
    guard !entries.isEmpty else { return [] }
    if let malformed = entries.first(where: { !NotebookTopics.isKey($0.topic) }) { throw .malformedTopic(malformed.topic) }
    try requireNovel(novel, in: transaction)
    let records = entries.map { row(for: $0, novel: novel) }
    try check(records, against: try load(novel, in: transaction), retiring: nil)
    for record in records { try append(record, in: &transaction) }
    return records
  }

  @discardableResult
  public static func record(_ entry: NewNotebookEntry, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> NotebookEntryRecord {
    try record([entry], novel: novel, in: &transaction)[0]
  }

  // ledger.service.ts:119, ledger.dto.ts:63
  @discardableResult
  public static func recordByAuthor(_ entry: AuthorNotebookEntry, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> NotebookEntryRecord {
    guard authorKinds.contains(entry.kind) else { throw .kindNotAllowed(entry.kind.rawValue) }
    try require(statement: entry.statement, why: entry.why)
    if NotebookTopics.isReserved(entry.topic) { throw .reservedTopic(entry.topic) }
    let payload = entry.payload.map(JSONValue.object)
    return try record(
      NewNotebookEntry(kind: entry.kind, topic: entry.topic, statement: entry.statement, why: entry.why, decidedBy: .author, payload: payload), novel: novel, in: &transaction)
  }

  // ledger.service.ts:128
  @discardableResult
  public static func supersede(_ id: UUID, with next: NotebookSuccessor, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> NotebookEntryRecord {
    try requireNovel(novel, in: transaction)
    let ledger = try load(novel, in: transaction)
    return try succeed(try active(id, in: ledger), with: next, novel: novel, ledger: ledger, in: &transaction)
  }

  // ledger.service.ts:152, ledger.dto.ts:80
  @discardableResult
  public static func supersedeByAuthor(_ id: UUID, rewrite: NotebookRewrite, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> NotebookEntryRecord {
    if let kind = rewrite.kind, !supersedeKinds.contains(kind) { throw .kindNotAllowed(kind.rawValue) }
    try require(statement: rewrite.statement, why: rewrite.why)
    try require(field: "writerLine", rewrite.writerLine, limit: writerLineLimit)
    if let alternatives = rewrite.rejectedAlternatives, alternatives.count > alternativesLimit { throw .tooMany(field: "rejectedAlternatives", limit: alternativesLimit) }

    let ledger = try load(novel, in: transaction)
    let previous = try active(id, in: ledger)
    try requireNovel(novel, in: transaction)
    return try succeed(previous, with: try rewritten(previous, rewrite), novel: novel, ledger: ledger, in: &transaction)
  }

  // ledger.service.ts:146
  @discardableResult
  public static func withdraw(_ id: UUID, reason: String, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) -> NotebookWithdrawalRecord {
    try require(field: "reason", reason, limit: statementLimit)
    if reason.jsTrim().isEmpty { throw .blank(field: "reason") }
    try requireNovel(novel, in: transaction)
    _ = try active(id, in: try load(novel, in: transaction))
    let withdrawal = NotebookWithdrawalRecord(novel: novel, entry: id, reason: reason.jsTrim())
    do throws(StoreError) { _ = try withdrawal.append(in: &transaction) } catch { throw .store(error) }
    return withdrawal
  }

  private static func succeed(
    _ previous: NotebookEntry, with next: NotebookSuccessor, novel: UUID, ledger: NotebookLedger, in transaction: inout WriteTransaction
  ) throws(NotebookError) -> NotebookEntryRecord {
    let entry = NewNotebookEntry(
      kind: next.kind, topic: previous.record.topic, statement: next.statement, why: next.why, rejectedAlternatives: next.rejectedAlternatives, writerLine: next.writerLine,
      decidedBy: next.decidedBy, stepKey: next.stepKey, payload: next.payload, links: next.links, idea: next.idea)
    let record = row(for: entry, novel: novel, supersedes: previous.id)
    try check([record], against: ledger, retiring: previous)
    try append(record, in: &transaction)
    return record
  }

  // ledger.service.ts:24
  private static func row(for entry: NewNotebookEntry, novel: UUID, supersedes: UUID? = nil) -> NotebookEntryRecord {
    NotebookEntryRecord(
      novel: novel, entryKind: .known(entry.kind), topic: entry.topic, statement: entry.statement.jsTrim(), why: nonEmpty(entry.why?.jsTrim()),
      rejectedAlternatives: entry.rejectedAlternatives, writerLine: nonEmpty(entry.writerLine?.jsTrim()), decidedBy: .known(entry.decidedBy), stepKey: entry.stepKey,
      payload: entry.payload, links: entry.links, supersedes: supersedes, idea: entry.idea?.ideaId, rejectionScope: entry.idea.map { .known($0.scope) },
      rejectionAnchor: entry.idea?.anchor.flatMap { $0.isNull ? nil : $0 })
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }

  // ledger.service.ts:53
  private static func rewritten(_ previous: NotebookEntry, _ rewrite: NotebookRewrite) throws(NotebookError) -> NotebookSuccessor {
    guard let kind = previous.record.entryKind.known, previous.record.rejectionScope.map({ $0.known != nil }) ?? true else { throw .entryNotUnderstood(previous.id) }
    let superseded = SupersededLedgerEntry(
      kind: kind, why: previous.record.why, writerLine: previous.record.writerLine, rejectedAlternatives: previous.record.rejectedAlternatives, payload: previous.record.payload,
      links: previous.record.links.json, stepKey: previous.record.stepKey, ideaId: previous.record.idea, rejectionScope: previous.record.rejectionScope?.known,
      rejectionAnchor: previous.record.rejectionAnchor)
    let input = AuthorSupersession(
      kind: rewrite.kind.flatMap { AuthorSupersedeKind(rawValue: $0.rawValue) }, statement: rewrite.statement, why: rewrite.why, writerLine: rewrite.writerLine,
      rejectedAlternatives: rewrite.rejectedAlternatives, payload: rewrite.payload.map(JSONValue.object))
    let result: SupersedingEntry
    do throws(LedgerRuleError) { result = try authorSuccessor(superseded, input) } catch { throw .onlyDecisionOrSystemDetailBecomesDecision }
    return NotebookSuccessor(
      kind: result.kind, decidedBy: result.decidedBy, statement: result.statement, why: result.why, rejectedAlternatives: result.rejectedAlternatives,
      writerLine: result.writerLine, stepKey: result.stepKey, payload: result.payload, links: NotebookLinks(json: result.links) ?? NotebookLinks(),
      idea: result.idea.map { NotebookIdeaRejection(ideaId: $0.ideaId, scope: $0.scope, anchor: $0.anchor) })
  }

  private static func active(_ id: UUID, in ledger: NotebookLedger) throws(NotebookError) -> NotebookEntry {
    guard let entry = ledger.entry(id) else { throw .entryNotFound(id) }
    guard entry.status == .active else { throw .entryNotActive(id) }
    return entry
  }

  // ledger.ts:78 rejection_check, ledger.ts:73 the unique idea index over active rows, ledger.ts:59 column lengths
  private static func check(_ records: [NotebookEntryRecord], against ledger: NotebookLedger, retiring previous: NotebookEntry?) throws(NotebookError) {
    var rejected = Set(ledger.active().filter { $0.id != previous?.id }.compactMap(\.record.idea))
    for record in records {
      if let stepKey = record.stepKey, stepKey.jsLength > stepKeyLimit { throw .tooLong(field: "stepKey", limit: stepKeyLimit) }
      try checkRejection(of: record)
      guard let idea = record.idea else { continue }
      guard rejected.insert(idea).inserted else { throw .ideaAlreadyRejected(idea) }
    }
  }

  private static func checkRejection(of record: NotebookEntryRecord) throws(NotebookError) {
    guard let idea = record.idea else {
      guard record.rejectionScope == nil, record.rejectionAnchor == nil else { throw .invalidRejection("scope or anchor without an idea") }
      return
    }
    if idea.jsLength > ideaIdLimit { throw .tooLong(field: "idea", limit: ideaIdLimit) }
    guard record.entryKind == .known(.rejected) else { throw .invalidRejection("an idea belongs to a rejected entry") }
    guard let scope = record.rejectionScope else { throw .invalidRejection("the scope is missing") }
    guard (scope == .known(.never)) == (record.rejectionAnchor == nil) else { throw .invalidRejection("the anchor is missing or unexpected for this scope") }
  }

  private static func require(statement: String, why: String?) throws(NotebookError) {
    try require(field: "statement", statement, limit: statementLimit)
    if statement.jsTrim().isEmpty { throw .blank(field: "statement") }
    try require(field: "why", why, limit: whyLimit)
  }

  private static func require(field: String, _ value: String?, limit: Int) throws(NotebookError) {
    if let value, value.jsLength > limit { throw .tooLong(field: field, limit: limit) }
  }

  private static func requireNovel(_ novel: UUID, in transaction: borrowing some StateReading & ~Copyable) throws(NotebookError) {
    let reading: RecordReading<NovelRecord>
    do throws(StoreError) { reading = try NovelRecord.read(id: novel, in: transaction) } catch { throw .store(error) }
    if case .absent = reading { throw .novelNotFound(novel) }
  }

  private static func load(_ novel: UUID, in transaction: borrowing some StateReading & ~Copyable) throws(NotebookError) -> NotebookLedger {
    do throws(StoreError) { return try NotebookLedger.load(novel: novel, in: transaction) } catch { throw .store(error) }
  }

  private static func append(_ record: NotebookEntryRecord, in transaction: inout WriteTransaction) throws(NotebookError) {
    do throws(StoreError) { _ = try record.append(in: &transaction) } catch { throw .store(error) }
  }
}

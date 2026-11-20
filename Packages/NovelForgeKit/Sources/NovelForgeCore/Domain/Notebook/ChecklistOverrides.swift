import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/new-novel/new-novel.service.ts:81-97 (new-novel.controller.ts:51-61): an override is a system entry at progress.<key>
public enum ChecklistOverrides {
  static let clearedReason = "the author cleared the checklist override"
  static let replacedReason = "the author replaced the checklist override"

  // new-novel.service.ts:81: the reference supersedes the oldest active entry at the topic; here the one in force is superseded and any other is withdrawn,
  // so the topic converges to one active entry. The entry is written even when the status is unchanged, as there.
  @discardableResult
  public static func set(_ key: ProgressItemKey, to status: ProgressOverrideKind, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError)
    -> NotebookEntryRecord
  {
    let topic = topic(of: key)
    let statement = status == .undecided ? "Marked undecided for now." : "Dismissed from the checklist."
    let payload = JSONValue.object(["status": .string(status.rawValue)])
    let active = try activeEntries(at: topic, novel: novel, in: transaction)
    guard let kept = inForce(active).flatMap({ id in active.first { $0.id == id } }) ?? active.last else {
      return try Notebook.record(NewNotebookEntry(kind: .system, topic: topic, statement: statement, decidedBy: .system, payload: payload), novel: novel, in: &transaction)
    }
    for other in active where other.id != kept.id { try Notebook.withdraw(other.id, reason: replacedReason, novel: novel, in: &transaction) }
    return try Notebook.supersede(kept.id, with: NotebookSuccessor(kind: .system, decidedBy: .system, statement: statement, payload: payload), novel: novel, in: &transaction)
  }

  // new-novel.service.ts:90
  public static func clear(_ key: ProgressItemKey, novel: UUID, in transaction: inout WriteTransaction) throws(NotebookError) {
    for entry in try activeEntries(at: topic(of: key), novel: novel, in: transaction) {
      try Notebook.withdraw(entry.id, reason: clearedReason, novel: novel, in: &transaction)
    }
  }

  // progress.ts:30 over the active entries oldest first (ledger-entries.ts:12): the last valid override at each key
  static func overrides(_ active: [NotebookEntryRecord]) -> [JSString: ProgressOverride<UUID>] {
    progressOverridesFrom(active.map { ProgressOverrideEntry(id: $0.id, kind: $0.entryKind.rawValue, topic: $0.topic, payload: $0.payload) })
  }

  static func topic(of key: ProgressItemKey) -> String { progressTopicPrefix + key.rawValue }

  private static func inForce(_ active: [NotebookEntryRecord]) -> UUID? {
    overrides(active).values.first?.entryId
  }

  // ledger-entries.ts:19: the exact topic, oldest first
  private static func activeEntries(at topic: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(NotebookError) -> [NotebookEntryRecord] {
    let ledger: NotebookLedger
    do throws(StoreError) { ledger = try NotebookLedger.load(novel: novel, in: transaction) } catch { throw .store(error) }
    return ledger.active().filter { $0.record.topic.utf8.elementsEqual(topic.utf8) }.map(\.record)
  }
}

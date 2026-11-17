import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/refinement/chat-session.service.ts. Across devices each operation writes one field of the session record, so a rename,
/// a mode switch and an archive made on two devices all stand, the later clock wins within one field, and a deletion is a `removed` flag no other operation
/// writes back. A change that leaves its field as it is writes nothing, so a stale device repeating it cannot reorder the list or undo a newer change.
enum ChatSessionOperations {
  // chat-session.service.ts:52-61: a chat starts untitled, in `auto` mode unless the author picks one
  static func create(novel: UUID, mode: ChatSessionMode = .auto, id: UUID = UUID(), in transaction: inout WriteTransaction) throws(ChatSessionError)
    -> ChatSessionRecord
  {
    do throws(DomainError) {
      try transaction.requireNovel(novel)
    } catch {
      if case .store(let cause) = error { throw .store(cause) }
      throw .novelNotFound(novel)
    }
    let record: ChatSessionRecord
    do throws(ChatRecordError) {
      record = try ChatSessionRecord(id: id, novel: novel, mode: mode)
    } catch {
      throw .record(error)
    }
    try stored { () throws(StoreError) in _ = try record.create(in: &transaction) }
    return record
  }

  // chat-session.service.ts:63-71 (title); a nil title clears the author's name, leaving the automatic one
  static func rename(_ session: UUID, novel: UUID, title: String?, in transaction: inout WriteTransaction) throws(ChatSessionError) {
    let record = try live(session, novel: novel, in: transaction)
    var edit = ChatSessionEdit()
    do throws(ChatRecordError) {
      try edit.rename(title)
    } catch {
      throw .record(error)
    }
    guard record.title != title else { return }
    try write(edit, to: session, in: &transaction)
  }

  // chat-session.service.ts:63-71 (mode)
  static func setMode(_ session: UUID, novel: UUID, mode: ChatSessionMode, in transaction: inout WriteTransaction) throws(ChatSessionError) {
    let record = try live(session, novel: novel, in: transaction)
    guard record.mode != .known(mode) else { return }
    var edit = ChatSessionEdit()
    edit.switchMode(to: mode)
    try write(edit, to: session, in: &transaction)
  }

  // chat-session.service.ts:102-107, chat.controller.ts:116-128
  static func setStatus(_ session: UUID, novel: UUID, status: ChatSessionStatus, in transaction: inout WriteTransaction) throws(ChatSessionError) {
    let record = try live(session, novel: novel, in: transaction)
    guard record.status != .known(status) else { return }
    var edit = ChatSessionEdit()
    edit.setStatus(status)
    try write(edit, to: session, in: &transaction)
  }

  /// chat-session.service.ts:109-114 deletes the row and cascades its messages. Here the session is removed, never purged: its items stay, so a lock the
  /// unrestricted text placed holds (ChatUnrestrictedLock), its cards stay in the change history, and the transcript is hidden by the removal alone. This
  /// device's turns and replayed exchanges of the session go in the same transaction. A chat this version cannot read can still be deleted.
  static func delete(_ session: UUID, novel: UUID, in transaction: inout WriteTransaction) throws(ChatSessionError) {
    _ = try lookup(session, novel: novel, in: transaction)
    try stored { () throws(StoreError) in
      _ = try ChatSessionRecord.remove(id: session, in: &transaction)
      try ChatLocalCleanup.forget(session: session, in: transaction.database)
    }
  }

  /// The session as the reference's `getSession` (chat-session.service.ts:96-100) finds it: of this novel and not deleted, or CHT_001.
  static func live<Transaction: StateReading & ~Copyable>(_ session: UUID, novel: UUID, in transaction: borrowing Transaction) throws(ChatSessionError)
    -> ChatSessionRecord
  {
    switch try lookup(session, novel: novel, in: transaction) {
    case .live(let record): return record
    case .unreadable: throw .unreadable(session)
    }
  }

  private enum Lookup {
    case live(ChatSessionRecord)
    case unreadable
  }

  /// An unreadable record counts as this novel's while its own `novel` member says so and its `removed` flag does not say it was deleted.
  private static func lookup<Transaction: StateReading & ~Copyable>(_ session: UUID, novel: UUID, in transaction: borrowing Transaction) throws(ChatSessionError)
    -> Lookup
  {
    let ref = ChatSessionRecord.ref(session)
    let state = try stored { () throws(StoreError) in try transaction.state(of: ref, scope: .vault) }
    switch ChatSessionRecord.reading(state, of: ref) {
    case .absent:
      throw .notFound(session)
    case .readable(let entry):
      guard entry.record.novel == novel, !entry.isRemoved else { throw .notFound(session) }
      return .live(entry.record)
    case .unreadable:
      guard case .record(let record)? = state, record[field: ChatSessionField.novel.rawValue].flatMap({ UUID(json: $0.value) }) == novel,
        record[field: CommonField.removed.rawValue]?.value != .bool(true)
      else { throw .notFound(session) }
      return .unreadable
    }
  }

  private static func write(_ edit: ChatSessionEdit, to session: UUID, in transaction: inout WriteTransaction) throws(ChatSessionError) {
    try stored { () throws(StoreError) in _ = try ChatSessionRecord.edit(id: session, edit, in: &transaction) }
  }

  static func stored<T>(_ body: () throws(StoreError) -> T) throws(ChatSessionError) -> T {
    do throws(StoreError) {
      return try body()
    } catch {
      throw .store(error)
    }
  }
}

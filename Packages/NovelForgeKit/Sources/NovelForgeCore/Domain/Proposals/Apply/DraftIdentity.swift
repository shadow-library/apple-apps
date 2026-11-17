import Foundation
import ShadowCore
import ShadowStore

/// What a passage anchor's `draftId` names. The reference names a draft by its row id, which a removal and a recreate replace; a draft record keeps its
/// natural key, but its `removed` register is written only by its create, its restores and its removal, so while it is live that write's clock names the
/// record's current life; a removed draft takes no rewrite.
enum DraftIdentity {
  static func of(_ state: EntityState?) -> String? {
    guard case .revisioned(let revisioned)? = state, let life = revisioned[field: CommonField.removed.rawValue] else { return nil }
    return life.clock.description
  }

  static func current<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(StoreError) -> String? {
    guard let ref = try? DraftRecord.ref(novel: novel, chapter: chapter) else { return nil }
    return of(try transaction.state(of: ref, scope: .vault))
  }
}

import Foundation
import ShadowCore
import ShadowStore

/// Unrestricted is one-way after first use (plan decision of revision 2; shadow-native-apps-plan.md:715): a novel leaves it only while none of its chats, a
/// deleted one included, and none of its drafts or canon may hold unrestricted text (`UnrestrictedLock`). A lock this device cannot read counts as held. The
/// reference switches freely and keeps unrestricted prose from a standard model by isolating it, which is not ported yet. The guard is local: the novel's
/// content mode is a register, so a switch made on a device that had not yet received the locking text can still win by clock; consumers therefore key off
/// the lock itself (`ChatWindow.lock`, `UnrestrictedLock`) or the chapter's own route, never off the novel's mode alone.
enum ChatUnrestrictedSwitch {
  static func requireSwitchable(novel: UUID, to mode: StoredEnum<ContentMode>, in transaction: borrowing WriteTransaction) throws(DomainError) {
    guard mode != .known(.unrestricted), case .live(let record) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self),
      record.contentMode != .known(.standard)
    else { return }
    let lock: UnrestrictedLock
    do throws(StoreError) {
      lock = try UnrestrictedLock.load(novel, in: ReadTransaction(database: transaction.database, registry: NovelForgeSchema.registry))
    } catch {
      throw .store(error)
    }
    guard !lock.isLocked else { throw .unrestrictedLocked }
  }
}

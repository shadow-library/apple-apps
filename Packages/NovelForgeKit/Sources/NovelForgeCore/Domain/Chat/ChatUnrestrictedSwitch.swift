import Foundation
import ShadowCore
import ShadowStore

/// Unrestricted is one-way after first use (plan decision of revision 2; shadow-native-apps-plan.md:715): a novel leaves it only while none of its chats,
/// a deleted one included, may hold unrestricted text. A lock this device cannot read counts as held. The reference switches freely and keeps unrestricted
/// prose from a standard model by isolating it, which is not ported yet. Unrestricted chapters lock it too once chapters are written in phase 7. The guard is
/// local: the novel's content mode is a register, so a switch made on a device that had not yet received the locking reply can still win by clock; chat
/// consumers therefore key off the lock itself (`ChatWindow.lock`, `ChatSessions.holdsUnrestrictedText`), never off the novel's mode alone.
enum ChatUnrestrictedSwitch {
  static func requireSwitchable(novel: UUID, to mode: StoredEnum<ContentMode>, in transaction: borrowing WriteTransaction) throws(DomainError) {
    guard mode != .known(.unrestricted), case .live(let record) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self),
      record.contentMode != .known(.standard)
    else { return }
    let sessions: ChatSessions
    do throws(StoreError) {
      sessions = try ChatSessions.load(novel, in: ReadTransaction(database: transaction.database, registry: NovelForgeSchema.registry))
    } catch {
      throw .store(error)
    }
    guard sessions.holdsUnrestrictedText == .available(false) else { throw .unrestrictedLocked }
  }
}

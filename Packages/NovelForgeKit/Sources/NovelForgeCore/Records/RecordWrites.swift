import Foundation
import ShadowCore
import ShadowStore

extension NovelForgeRecord {
  public func create(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref, storedMembers)
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<Field>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref, edit.members)
  }
}

extension RemovableRecord {
  public func restore(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try create(in: &transaction)
  }

  public static func remove(_ ref: EntityRef, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref, [CommonField.removed.rawValue: .bool(true)])
  }
}

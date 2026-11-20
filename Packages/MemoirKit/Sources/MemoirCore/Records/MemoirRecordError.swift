import ShadowCore
import ShadowStore

public enum MemoirUnreadable: ShadowError, Equatable {
  case wrongShape
  case identity(EntityRef)
  case missing(field: String)
  case invalid(field: String)
  case unexpected(field: String)
  case keyMismatch(EntityRef)
  case command(MemoirCommandError)

  public var code: String {
    switch self {
    case .wrongShape: "memoir_record.wrong_shape"
    case .identity: "memoir_record.identity"
    case .missing: "memoir_record.missing_field"
    case .invalid: "memoir_record.invalid_field"
    case .unexpected: "memoir_record.unexpected_field"
    case .keyMismatch: "memoir_record.key_mismatch"
    case .command: "memoir_record.command"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .wrongShape: "The stored state does not have this kind's shape."
    case .identity(let ref): "\(ref.kind)/\(ref.key) does not identify a record of this kind."
    case .missing(let field): "The stored record has no \"\(field)\" field."
    case .invalid(let field): "The stored record's \"\(field)\" field has the wrong type or form."
    case .unexpected(let field): "The stored item carries \"\(field)\", which this kind does not have."
    case .keyMismatch(let ref): "The stored natural key does not hash to \(ref.kind)/\(ref.key)."
    case .command(let error): "The stored command is invalid: \(error.errorDescription ?? error.code)"
    }
  }
}

public enum MemoirRecordError: ShadowError {
  case store(StoreError)
  case absent(EntityRef)
  case unreadable(EntityRef, MemoirUnreadable)
  case firstWriterField(kind: String, field: String)
  case identityChanged(EntityRef)
  case conflictingItem(EntityRef)

  public var code: String {
    switch self {
    case .store: "memoir_record.store"
    case .absent: "memoir_record.absent"
    case .unreadable: "memoir_record.unreadable"
    case .firstWriterField: "memoir_record.first_writer_field"
    case .identityChanged: "memoir_record.identity_changed"
    case .conflictingItem: "memoir_record.conflicting_item"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): "The store refused the write: \(error.errorDescription ?? error.code)"
    case .absent(let ref): "\(ref.kind)/\(ref.key) is not in the store."
    case .unreadable(let ref, let reason): "\(ref.kind)/\(ref.key) cannot be read: \(reason.errorDescription ?? reason.code)"
    case .firstWriterField(let kind, let field): "\(kind).\(field) keeps its first value; an edit cannot change it."
    case .identityChanged(let ref): "An edit of \(ref.kind)/\(ref.key) changed what identifies it."
    case .conflictingItem(let ref): "\(ref.kind)/\(ref.key) already holds a different item."
    }
  }
}

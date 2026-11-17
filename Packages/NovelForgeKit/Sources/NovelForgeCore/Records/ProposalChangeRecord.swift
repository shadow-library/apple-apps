import Foundation
import ShadowCore
import ShadowStore

extension ProposalChangeField: FieldName {}
extension ProposalChangeUndoMember: FieldName {}
extension ProposalChangeResultMember: FieldName {}

/// apps/novel-forge-server/src/modules/refinement/op-undo.ts:5-8. The inverse stays the stored op object: OP_SPECS refuses the nulls an inverse restores
/// (apply/apply.types.ts:52-54), so it is not revalidated as a change-set operation.
public struct ProposalChangeUndo: Sendable, Equatable {
  public let inverse: JSONValue
  let priorState: ArtifactStates
  let postState: ArtifactStates
  public private(set) var unrecognised: [String: JSONValue]

  init(inverse: OrderedJSONObject, priorState: ArtifactStates, postState: ArtifactStates) throws(ProposalRecordError) {
    guard let stored = OrderedJSON.object(inverse).storable, Self.isOp(stored) else { throw .unstorableInverse }
    self.init(stored: stored, priorState: priorState, postState: postState)
  }

  private init(stored inverse: JSONValue, priorState: ArtifactStates, postState: ArtifactStates) {
    self.inverse = inverse
    self.priorState = priorState
    self.postState = postState
    unrecognised = [:]
  }

  private static func isOp(_ value: JSONValue) -> Bool {
    value["op"]?.stringValue != nil
  }
}

extension ProposalChangeUndo: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ProposalChangeUndoMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      let inverse: JSONValue = try reader.required(.inverse)
      guard Self.isOp(inverse) else { return nil }
      self.init(stored: inverse, priorState: try reader.required(.priorState), postState: try reader.required(.postState))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ProposalChangeUndoMember>()
    fields.put(.inverse, inverse)
    fields.put(.priorState, priorState)
    fields.put(.postState, postState)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/modules/refinement/apply/apply.types.ts:21-24
public struct ProposalChangeResult: Sendable, Equatable {
  public var error: String?
  public var note: String?
  public var result: JSONValue?
  public private(set) var unrecognised: [String: JSONValue]

  public init(error: String? = nil, note: String? = nil, result: JSONValue? = nil) {
    self.error = error
    self.note = note
    self.result = result
    unrecognised = [:]
  }

  var settledStatus: ProposalChangeStatus { error == nil ? .applied : .failed }
}

extension ProposalChangeResult: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ProposalChangeResultMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(error: try reader.optional(.error), note: try reader.optional(.note), result: try reader.optional(.result))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ProposalChangeResultMember>()
    fields.put(.error, error)
    fields.put(.note, note)
    fields.put(.result, result)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

public enum ActionSettlement: Sendable, Equatable {
  case settled(ChangeRecord)
  case alreadySettled(StoredEnum<ProposalChangeStatus>)
}

/// What an index of a card amounts to: a recorded change; on an applied proposal, `awaiting` when the first applier selected it and its record has not
/// arrived, `declined` when it did not select it.
public enum ProposalChangeEntry: Sendable, Equatable {
  case recorded(ProposalChangeRecord)
  case unreadable(UnreadableReason)
  case awaiting
  case declined
  case notApplied
}

/// Written only for an index an apply selected; undo, redo and revert are guarded by this change's own `undo`, never by the proposal's `applied`.
public struct ProposalChangeRecord: KeyedRecord {
  public static let kind = NovelForgeKind.proposalChange

  public let key: NovelForgeKey
  public let proposal: UUID
  public let index: Int
  public let status: StoredEnum<ProposalChangeStatus>
  public let undo: ProposalChangeUndo?
  let undoneState: ArtifactStates?
  public let result: ProposalChangeResult?

  init(novel: UUID, proposal: UUID, index: Int, status: ProposalChangeStatus, undo: ProposalChangeUndo? = nil, result: ProposalChangeResult? = nil) throws(NovelForgeKeyError) {
    key = try .proposalChangeKey(novel: novel, proposal: proposal, index: index)
    self.proposal = proposal
    self.index = index
    self.status = .known(status)
    self.undo = undo
    undoneState = nil
    self.result = result
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<ProposalChangeField>) throws(UnreadableReason) {
    guard case .proposalChange(let proposal, let index) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.proposal = proposal
    self.index = index
    status = try reader.required(.status)
    undo = try Self.member(.undo, of: reader, as: ProposalChangeUndo.self)
    undoneState = try Self.member(.undoneState, of: reader, as: ArtifactStates.self)
    result = try Self.member(.result, of: reader, as: ProposalChangeResult.self)
  }

  // First writer wins: `undo` and `result` are written only when they hold something, and `undone_state` only by an undo.
  public var fields: RecordFields<ProposalChangeField> {
    var fields = RecordFields<ProposalChangeField>()
    fields.put(.status, status)
    if let undo { fields.put(.undo, undo) }
    if let undoneState { fields.put(.undoneState, undoneState) }
    if let result { fields.put(.result, result) }
    return fields
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<ProposalChangeField>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is written only by an apply, undo, redo or action outcome")
  }

  /// An action's outcome: a stored result settles it (failed when it holds an error), and only without one does the status register speak, because a
  /// concurrent second applier can write `pending` over a settled status. F16's resume and F23a read this for action changes, never `status`.
  public var actionOutcome: StoredEnum<ProposalChangeStatus> {
    result.map { .known($0.settledStatus) } ?? status
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .record(let record) = state else { return false }
    return record[field: CommonField.naturalKey.rawValue] == nil
  }

  private static func member<Value: JSONReadable>(_ field: ProposalChangeField, of reader: FieldReader<ProposalChangeField>, as _: Value.Type) throws(UnreadableReason)
    -> Value?
  {
    let stored: JSONValue? = try reader.optional(field)
    guard let stored else { return nil }
    guard let value = Value(json: stored) else { throw .invalid(field: field.rawValue) }
    return value
  }
}

extension ProposalChangeRecord {
  public static func ref(novel: UUID, proposal: UUID, index: Int) throws(NovelForgeKeyError) -> EntityRef {
    try NovelForgeKey.proposalChange(novel: novel, proposal: proposal, index: index)
  }

  /// One entry per operation of the card, by index; read by key, so records of indexes the card does not have are never listed. Without the applier's
  /// selection an unrecorded index of an applied proposal reads as `awaiting`, never `declined`.
  public static func changes<Transaction: StateReading & ~Copyable>(of proposal: ProposalRecord, in transaction: borrowing Transaction) throws(StoreError)
    -> [ProposalChangeEntry]
  {
    var entries = [ProposalChangeEntry]()
    for index in proposal.card.changeSet.indices {
      let changeRef: EntityRef
      do throws(NovelForgeKeyError) {
        changeRef = try Self.ref(novel: proposal.novel, proposal: proposal.id, index: index)
      } catch {
        entries.append(.unreadable(.naturalKey(error)))
        continue
      }
      switch try read(changeRef, in: transaction) {
      case .readable(let entry): entries.append(.recorded(entry.record))
      case .unreadable(let reason): entries.append(.unreadable(reason))
      case .absent: entries.append(unrecorded(index, of: proposal))
      }
    }
    return entries
  }

  static func recordUndo(_ ref: EntityRef, undoneState: ArtifactStates, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try undoable(ref, in: transaction)
    return try transaction.set(
      ref, [ProposalChangeField.status.rawValue: StoredEnum.known(ProposalChangeStatus.reverted).json, ProposalChangeField.undoneState.rawValue: undoneState.json])
  }

  static func recordRedo(_ ref: EntityRef, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try undoable(ref, in: transaction)
    return try transaction.set(ref, [ProposalChangeField.status.rawValue: StoredEnum.known(ProposalChangeStatus.applied).json])
  }

  /// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:259-280: a pending action settles once, failed when its result holds an error.
  static func settleAction(_ ref: EntityRef, result: ProposalChangeResult, in transaction: inout WriteTransaction) throws(StoreError) -> ActionSettlement {
    let change = try existing(ref, in: transaction)
    guard change.status == .known(.pending), change.result == nil else { return .alreadySettled(change.actionOutcome) }
    return .settled(
      try transaction.set(ref, [ProposalChangeField.status.rawValue: StoredEnum.known(result.settledStatus).json, ProposalChangeField.result.rawValue: result.json]))
  }

  private static func unrecorded(_ index: Int, of proposal: ProposalRecord) -> ProposalChangeEntry {
    guard proposal.decision == .known(.applied) else { return .notApplied }
    guard let application = proposal.application, !application.selected.contains(index) else { return .awaiting }
    return .declined
  }

  private static func undoable(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) {
    guard try existing(ref, in: transaction).undo != nil else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) records no undo") }
  }

  private static func existing(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) -> ProposalChangeRecord {
    guard case .readable(let entry) = try read(ref, in: transaction) else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a readable proposal change") }
    return entry.record
  }
}

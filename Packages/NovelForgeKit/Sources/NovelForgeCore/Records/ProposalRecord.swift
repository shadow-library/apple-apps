import Foundation
import ShadowCore
import ShadowStore
import ShadowText

extension ProposalField: FieldName {}
extension ProposalCardMember: FieldName {}
extension ProposalAppliedMember: FieldName {}

enum ProposalDiagnosticMember: String, CaseIterable, FieldName {
  case kind
  case message
  case data
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:154
public enum ProposalKind: String, CaseIterable, Sendable {
  case chat
  case hub
  case premiseEnhance = "premise_enhance"
  case bibleAudit = "bible_audit"
  case chapterExtract = "chapter_extract"
  case plugin
  case chapterPlan = "chapter_plan"
  case organise
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:7
public enum ProposalDiagnosticKind: String, CaseIterable, Sendable {
  case pooling
  case giveAway = "give_away"
  case pov
  case density
  case other
}

public enum ProposalRecordError: ShadowError, Equatable {
  case unstorableOperation(index: Int)
  case unstorableInverse

  public var code: String {
    switch self {
    case .unstorableOperation: "proposal_record.unstorable_operation"
    case .unstorableInverse: "proposal_record.unstorable_inverse"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unstorableOperation(let index): "Operation \(index) holds a number or member names the vault cannot store exactly."
    case .unstorableInverse: "The inverse is not an operation object, or holds a number or member names the vault cannot store exactly."
    }
  }
}

extension OrderedJSON {
  // The vault holds integers only and compares member names canonically, so a fraction or two names equal under NFC cannot be stored as they are.
  var storable: JSONValue? {
    switch self {
    case .null: return .null
    case .bool(let flag): return .bool(flag)
    case .int(let number): return .int(number)
    case .double(let number): return Int64(exactly: number).map(JSONValue.int)
    case .string(let text): return .string(text)
    case .array(let items):
      let values = items.compactMap(\.storable)
      return values.count == items.count ? .array(values) : nil
    case .object(let record):
      var members = [String: JSONValue]()
      for entry in record.entries {
        guard let value = entry.value.storable, members.updateValue(value, forKey: entry.key) == nil else { return nil }
      }
      return .object(members)
    }
  }
}

/// A ref's state as recorded, keyed by the NFC form of the ref because natural keys are; an entry that does not decode, or two spellings of one ref
/// recorded with different states, read as unreadable, which never matches, so a guard over it reports a conflict.
struct ArtifactStates: Sendable, Equatable, JSONRepresentable {
  private(set) var byRef: [JSString: ArtifactState]

  init(_ states: [JSString: ArtifactState] = [:]) {
    self.init(entries: states.map { ($0.key.value, $0.value) })
  }

  init?(json: JSONValue) {
    guard let members = json.objectValue else { return nil }
    self.init(entries: members.map { ($0.key, ArtifactState(json: OrderedJSON($0.value)) ?? .unreadable) })
  }

  private init(entries: [(ref: String, state: ArtifactState)]) {
    byRef = Dictionary(entries.map { (Self.key($0.ref), $0.state) }) { first, second in first == second ? first : .unreadable }
  }

  subscript(ref: String) -> ArtifactState? { byRef[Self.key(ref)] }

  var refs: [String] { byRef.keys.sorted().map(\.value) }

  var json: JSONValue {
    .object(Dictionary(byRef.map { ($0.key.value, Self.json(of: $0.value)) }) { first, _ in first })
  }

  private static func json(of state: ArtifactState) -> JSONValue {
    ["exists": .bool(state.exists), "revision": state.revision.map { .int(Int64($0)) } ?? .null, "contentHash": state.contentHash.map(JSONValue.string) ?? .null]
  }

  private static func key(_ ref: String) -> JSString { JSString(ref.precomposedStringWithCanonicalMapping) }
}

/// One stored operation of a card, revalidated on every read; one that no longer validates keeps its index and stored form and carries the problems instead.
public struct ProposalOp: Sendable, Equatable {
  public let stored: JSONValue
  let op: ChangeOp?
  public let problems: [String]

  init(stored: JSONValue, index: Int) {
    self.stored = stored
    do throws(ChangeSetError) {
      let ops = try ValidatedChangeSet(.array([OrderedJSON(stored)]), options: ChangeSetValidationOptions(entityMaterialization: false)).ops
      op = ops.first
      problems = ops.count == 1 ? [] : ["changeSet[\(index)]: the stored operation could not be built"]
    } catch {
      op = nil
      switch error {
      case .notAllowedForScope(let found): problems = found.map { Self.located($0, at: index) }
      }
    }
  }

  private static func located(_ problem: String, at index: Int) -> String {
    let single = "changeSet[0]"
    guard problem.hasPrefix(single) else { return problem }
    return "changeSet[\(index)]" + problem.dropFirst(single.count)
  }
}

public struct ProposalDiagnostic: Sendable, Equatable {
  public var kind: StoredEnum<ProposalDiagnosticKind>
  public var message: String
  public var data: JSONValue?
  public private(set) var unrecognised: [String: JSONValue]

  public init(kind: StoredEnum<ProposalDiagnosticKind>, message: String, data: JSONValue? = nil) {
    self.kind = kind
    self.message = message
    self.data = data
    unrecognised = [:]
  }
}

extension ProposalDiagnostic: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ProposalDiagnosticMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(kind: try reader.required(.kind), message: try reader.required(.message), data: try reader.optional(.data))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ProposalDiagnosticMember>()
    fields.put(.kind, kind)
    fields.put(.message, message)
    if let data { fields.put(.data, data) }
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:160-175, written once when the proposal is staged
public struct ProposalCard: Sendable, Equatable {
  public let novel: UUID
  public let session: UUID?
  public let message: UUID?
  public let kind: StoredEnum<ProposalKind>
  public let summary: String?
  public let changeSet: [ProposalOp]
  let baseline: ArtifactStates
  public let warnings: [String]
  public let diagnostics: [ProposalDiagnostic]
  /// Provenance only: whether a proposal was superseded is its own `decision`, never this list.
  public let supersedes: [UUID]
  public let run: String?
  public private(set) var unrecognised: [String: JSONValue]

  // Each operation is kept in the form the vault stores and read back from it, so a staged card equals the card every device reads.
  init(
    novel: UUID, session: UUID? = nil, message: UUID? = nil, kind: StoredEnum<ProposalKind>, summary: String? = nil, changeSet: [ChangeOp], baseline: ArtifactStates,
    warnings: [String] = [], diagnostics: [ProposalDiagnostic] = [], supersedes: [UUID] = [], run: String? = nil
  ) throws(ProposalRecordError) {
    var ops = [ProposalOp]()
    for (index, op) in changeSet.enumerated() {
      guard let stored = OrderedJSON.object(op.fields).storable else { throw .unstorableOperation(index: index) }
      let kept = ProposalOp(stored: stored, index: index)
      guard kept.op != nil else { throw .unstorableOperation(index: index) }
      ops.append(kept)
    }
    self.init(
      novel: novel, session: session, message: message, kind: kind, summary: summary, ops: ops, baseline: baseline, warnings: warnings, diagnostics: diagnostics,
      supersedes: supersedes, run: run)
  }

  private init(
    novel: UUID, session: UUID?, message: UUID?, kind: StoredEnum<ProposalKind>, summary: String?, ops: [ProposalOp], baseline: ArtifactStates, warnings: [String],
    diagnostics: [ProposalDiagnostic], supersedes: [UUID], run: String?
  ) {
    self.novel = novel
    self.session = session
    self.message = message
    self.kind = kind
    self.summary = summary
    changeSet = ops
    self.baseline = baseline
    self.warnings = warnings
    self.diagnostics = diagnostics
    self.supersedes = supersedes
    self.run = run
    unrecognised = [:]
  }

  var ops: [ChangeOp?] { changeSet.map(\.op) }

  public var problems: [String] { changeSet.flatMap(\.problems) }
}

extension ProposalCard: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ProposalCardMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      let stored: [JSONValue] = try reader.required(.changeSet)
      self.init(
        novel: try reader.required(.novel), session: try reader.optional(.session), message: try reader.optional(.message), kind: try reader.required(.kind),
        summary: try reader.optional(.summary), ops: stored.enumerated().map { ProposalOp(stored: $1, index: $0) }, baseline: try reader.required(.baseline),
        warnings: try reader.optional(.warnings) ?? [], diagnostics: try reader.optional(.diagnostics) ?? [], supersedes: try reader.optional(.supersedes) ?? [],
        run: try reader.optional(.run))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ProposalCardMember>()
    fields.put(.novel, novel)
    fields.put(.session, session)
    fields.put(.message, message)
    fields.put(.kind, kind)
    fields.put(.summary, summary)
    fields.put(.changeSet, changeSet.map(\.stored))
    fields.put(.baseline, baseline)
    fields.put(.warnings, warnings)
    fields.put(.diagnostics, diagnostics)
    fields.put(.supersedes, supersedes)
    fields.put(.run, run)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

/// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:186-197; the first applier's provenance, never a guard for undo. `selected` lists the
/// indexes that apply recorded changes for, so an index whose record has not arrived yet is never mistaken for a declined one. The per-op `sources` live only
/// here, in the first applier's object: a concurrent applier's sources are not kept.
public struct ProposalApplication: Sendable, Equatable {
  public let selected: [Int]
  let postState: ArtifactStates
  public let sources: [StoredEnum<OpSource>]?
  public let automatic: Bool
  public private(set) var unrecognised: [String: JSONValue]

  init(selected: [Int], postState: ArtifactStates, sources: [StoredEnum<OpSource>]? = nil, automatic: Bool) {
    self.selected = selected
    self.postState = postState
    self.sources = sources
    self.automatic = automatic
    unrecognised = [:]
  }
}

extension ProposalApplication: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ProposalAppliedMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      let selected: [Int] = try reader.required(.selected)
      guard selected.allSatisfy({ $0 >= 0 }) else { return nil }
      self.init(selected: selected, postState: try reader.required(.postState), sources: try reader.optional(.sources), automatic: try reader.required(.automatic))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ProposalAppliedMember>()
    fields.put(.selected, selected)
    fields.put(.postState, postState)
    fields.put(.sources, sources)
    fields.put(.automatic, automatic)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

public enum ProposalDismissal: Sendable, Equatable {
  case superseded
  case discarded

  var decision: ProposalDecision {
    switch self {
    case .superseded: .superseded
    case .discarded: .discarded
    }
  }
}

public enum DecisionOutcome: Sendable, Equatable {
  case raised(ChangeRecord)
  case unchanged(StoredEnum<ProposalDecision>)
}

public enum ApplyRecording: Sendable, Equatable {
  case recorded(ChangeRecord)
  case notPending(StoredEnum<ProposalDecision>)
}

/// The card is first writer wins and the decision only rises (pending < superseded < discarded < applied); `conflicted` and a whole revert are derived, never stored.
public struct ProposalRecord: NovelForgeRecord {
  public static let kind = NovelForgeKind.proposal

  public let id: UUID
  public let card: ProposalCard
  public let decision: StoredEnum<ProposalDecision>
  public let application: ProposalApplication?

  public init(id: UUID, card: ProposalCard) {
    self.id = id
    self.card = card
    decision = .known(.pending)
    application = nil
  }

  public init(ref: EntityRef, reading reader: FieldReader<ProposalField>) throws(UnreadableReason) {
    guard ref.kind == Self.kind.entityKind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { throw .identity(ref) }
    let stored: JSONValue = try reader.required(.card)
    guard let card = ProposalCard(json: stored) else { throw .invalid(field: ProposalField.card.rawValue) }
    let applied: JSONValue? = try reader.optional(.applied)
    let application = try applied.map { json throws(UnreadableReason) in
      guard let application = ProposalApplication(json: json) else { throw .invalid(field: ProposalField.applied.rawValue) }
      return application
    }
    self.id = id
    self.card = card
    decision = try reader.required(.decision)
    self.application = application
  }

  public var novel: UUID { card.novel }
  public var ref: EntityRef { NovelForgeKey.proposal(id) }

  public var fields: RecordFields<ProposalField> {
    var fields = RecordFields<ProposalField>()
    fields.put(.card, card)
    fields.put(.decision, decision)
    if let application { fields.put(.applied, application) }
    return fields
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<ProposalField>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is written only by create, dismiss and apply")
  }

  public static func owner(of ref: EntityRef, in reader: FieldReader<ProposalField>) -> UUID? {
    guard let card: JSONValue = try? reader.optional(.card) else { return nil }
    return card[ProposalCardMember.novel.rawValue].flatMap(UUID.init(json:))
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .record(let record) = state else { return false }
    return record[field: ProposalField.card.rawValue] == nil
  }
}

extension ProposalRecord {
  public static func ref(id: UUID) -> EntityRef { NovelForgeKey.proposal(id) }

  public static func read<Transaction: StateReading & ~Copyable>(id: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<ProposalRecord> {
    try read(ref(id: id), in: transaction)
  }

  // A card this device cannot read can still be set aside: the decision only rises, whatever the card holds.
  public static func dismiss(_ ref: EntityRef, as dismissal: ProposalDismissal, in transaction: inout WriteTransaction) throws(StoreError) -> DecisionOutcome {
    guard case .record(let stored)? = try transaction.state(of: ref, scope: .vault), stored[field: ProposalField.card.rawValue] != nil else {
      throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) holds no proposal")
    }
    let current = stored[field: ProposalField.decision.rawValue].flatMap { StoredEnum<ProposalDecision>(json: $0.value) }
    if let current, let held = rank(of: current), held >= rank(of: dismissal.decision) { return .unchanged(current) }
    return .raised(try transaction.set(ref, [ProposalField.decision.rawValue: StoredEnum.known(dismissal.decision).json]))
  }

  /// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:119 (RFN_002): only a pending proposal is applied. The change records are written
  /// before the decision, so any prefix of this device's log that holds the decision holds every change it selected.
  static func recordApply(
    _ ref: EntityRef, changes: [ProposalChangeRecord], postState: ArtifactStates, sources: [StoredEnum<OpSource>]? = nil, automatic: Bool,
    in transaction: inout WriteTransaction
  ) throws(StoreError) -> ApplyRecording {
    guard case .readable(let entry) = try read(ref, in: transaction) else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a readable proposal") }
    let proposal = entry.record
    guard proposal.decision == .known(.pending) else { return .notPending(proposal.decision) }
    let selected = changes.map(\.index).sorted()
    let operations = proposal.card.changeSet.indices
    guard !selected.isEmpty, Set(selected).count == selected.count, selected.allSatisfy(operations.contains),
      changes.allSatisfy({ $0.proposal == proposal.id && $0.novel == proposal.novel })
    else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue): an apply records one change per selected operation of this proposal") }
    if let sources, sources.count != operations.count { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue): an apply carries one source per operation") }
    for change in changes { _ = try change.create(in: &transaction) }
    let application = ProposalApplication(selected: selected, postState: postState, sources: sources, automatic: automatic)
    let fields = [ProposalField.decision.rawValue: StoredEnum.known(ProposalDecision.applied).json, ProposalField.applied.rawValue: application.json]
    return .recorded(try transaction.set(ref, fields))
  }

  private static func rank(of decision: StoredEnum<ProposalDecision>) -> Int? {
    decision.known.map(rank(of:))
  }

  private static func rank(of decision: ProposalDecision) -> Int {
    ProposalDecision.allCases.firstIndex(of: decision) ?? 0
  }
}

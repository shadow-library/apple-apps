import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ProposalEntryCounts: Hashable, Sendable {
  public let applied: Int
  public let pending: Int
  public let failed: Int
  public let reverted: Int
  public let declined: Int
  public let awaiting: Int
  /// Unreadable and unrecognised entries.
  public let unreadable: Int

  init(applied: Int = 0, pending: Int = 0, failed: Int = 0, reverted: Int = 0, declined: Int = 0, awaiting: Int = 0, unreadable: Int = 0) {
    self.applied = applied
    self.pending = pending
    self.failed = failed
    self.reverted = reverted
    self.declined = declined
    self.awaiting = awaiting
    self.unreadable = unreadable
  }

  init(_ entries: [ProposalEntryRow]) {
    func count(_ states: ProposalChangeEntryState...) -> Int { entries.count { states.contains($0.state) } }
    self.init(
      applied: count(.applied), pending: count(.pending), failed: count(.failed), reverted: count(.reverted), declined: count(.declined), awaiting: count(.awaiting),
      unreadable: count(.unreadable, .unrecognised))
  }
}

/// A proposal as the chat and the change history read it: the merged decision with its rank in the merge order, and what its changes amount to.
public struct ProposalState: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_proposal"

  public let proposal: UUID
  public let novel: UUID
  public let readability: ProposalReadability
  public let session: UUID?
  public let message: UUID?
  public let kind: StoredEnum<ProposalKind>?
  public let decision: StoredEnum<ProposalDecision>?
  /// pending 0 < superseded 1 < discarded 2 < applied 3: concurrent decisions settle on the highest; nil when the decision is missing or unknown.
  public let rank: Int?
  /// The clock of the first-writer-wins `card`.
  public let staged: HLCTimestamp
  public let operations: Int?
  public let counts: ProposalEntryCounts

  init(
    proposal: UUID, novel: UUID, readability: ProposalReadability, session: UUID?, message: UUID?, kind: StoredEnum<ProposalKind>?,
    decision: StoredEnum<ProposalDecision>?, rank: Int?, staged: HLCTimestamp, operations: Int?, counts: ProposalEntryCounts
  ) {
    self.proposal = proposal
    self.novel = novel
    self.readability = readability
    self.session = session
    self.message = message
    self.kind = kind
    self.decision = decision
    self.rank = rank
    self.staged = staged
    self.operations = operations
    self.counts = counts
  }

  public init(row: Row) throws {
    self.init(
      proposal: try row.decode(UUID.self, forColumn: "proposal"), novel: try row.decode(UUID.self, forColumn: "novel"),
      readability: try row.decode(ProposalReadability.self, forColumn: "readability"), session: try row.decode(UUID?.self, forColumn: "session"),
      message: try row.decode(UUID?.self, forColumn: "message"), kind: try ChatColumns.stored(row, "kind"), decision: try ChatColumns.stored(row, "decision"),
      rank: try row.decode(Int?.self, forColumn: "rank"), staged: try ChatColumns.clock(row, "staged"), operations: try row.decode(Int?.self, forColumn: "operations"),
      counts: ProposalEntryCounts(
        applied: try row.decode(Int.self, forColumn: "applied"), pending: try row.decode(Int.self, forColumn: "pending"),
        failed: try row.decode(Int.self, forColumn: "failed"), reverted: try row.decode(Int.self, forColumn: "reverted"),
        declined: try row.decode(Int.self, forColumn: "declined"), awaiting: try row.decode(Int.self, forColumn: "awaiting"),
        unreadable: try row.decode(Int.self, forColumn: "unreadable")))
  }

  public var ref: EntityRef { NovelForgeKey.proposal(proposal) }

  public var isPending: Bool { decision == .known(.pending) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["proposal"] = proposal
    container["novel"] = novel
    container["readability"] = readability
    container["session"] = session
    container["message"] = message
    container["kind"] = kind?.rawValue
    container["decision"] = decision?.rawValue
    container["rank"] = rank
    container["staged"] = staged.description
    container["operations"] = operations
    container["applied"] = counts.applied
    container["pending"] = counts.pending
    container["failed"] = counts.failed
    container["reverted"] = counts.reverted
    container["declined"] = counts.declined
    container["awaiting"] = counts.awaiting
    container["unreadable"] = counts.unreadable
  }
}

public struct ProposalStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_proposal (
      proposal BLOB PRIMARY KEY, novel BLOB NOT NULL, readability TEXT NOT NULL, session BLOB, message BLOB, kind TEXT, decision TEXT, rank INTEGER,
      staged TEXT NOT NULL, operations INTEGER, applied INTEGER NOT NULL, pending INTEGER NOT NULL, failed INTEGER NOT NULL, reverted INTEGER NOT NULL,
      declined INTEGER NOT NULL, awaiting INTEGER NOT NULL, unreadable INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_proposal_novel ON nf_derived_proposal (novel, decision);
    CREATE INDEX nf_derived_proposal_session ON nf_derived_proposal (session);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .records([.proposal]) { [$0] },
      .outputs(of: ProposalChangeEntryDerivation.self) { [NovelForgeKey.proposal($0.proposal)] },
    ]
  }

  public static func key(of output: ProposalState) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ProposalState> {
    guard let proposal = ChatColumns.id(of: ref, .proposal) else { return ProposalState.filter(sql: "0") }
    return ProposalState.filter(Column("proposal") == proposal)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .proposal))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ProposalState] {
    guard let proposal = ProposalSnapshot(ref, try context.records.state(of: ref, scope: .vault)) else { return [] }
    let entries = try context.fetchAll(ProposalEntryRow.filter(Column("proposal") == proposal.id))
    let card = proposal.card
    return [
      ProposalState(
        proposal: proposal.id, novel: proposal.novel, readability: proposal.readability, session: card?.session, message: card?.message, kind: card?.kind,
        decision: proposal.decision, rank: ProposalSnapshot.rank(of: proposal.decision), staged: proposal.staged, operations: card?.changeSet.count,
        counts: ProposalEntryCounts(entries))
    ]
  }
}

import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore

/// One row per readable ledger entry, under the call it belongs to: the entry itself for a call, its parent for an attempt the call abandoned. `digest`
/// changes with the entry's merged state, so a call's cost hears of every entry `Ledger.entries(ofCall:)` reads.
public struct ModelCallIndexRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_model_call"

  public let entry: UUID
  public let call: UUID
  public let digest: String

  init(entry: UUID, call: UUID, digest: String) {
    self.entry = entry
    self.call = call
    self.digest = digest
  }

  public init(row: Row) throws {
    self.init(entry: try row.decode(UUID.self, forColumn: "entry"), call: try row.decode(UUID.self, forColumn: "call"), digest: try row.decode(String.self, forColumn: "digest"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["entry"] = entry
    container["call"] = call
    container["digest"] = digest
  }
}

public struct ModelCallIndexDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_model_call (entry BLOB PRIMARY KEY, call BLOB NOT NULL, digest TEXT NOT NULL) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.kit([LedgerSchema.modelCallKind]) { [$0] }]
  }

  public static func key(of output: ModelCallIndexRow) -> EntityRef { JobColumns.callRef(output.entry) }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ModelCallIndexRow> {
    guard let entry = JobColumns.uuid(of: ref, LedgerSchema.modelCallKind) else { return ModelCallIndexRow.filter(sql: "0") }
    return ModelCallIndexRow.filter(Column("entry") == entry)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(ofKit: LedgerSchema.modelCallKind))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ModelCallIndexRow] {
    guard let id = JobColumns.uuid(of: ref, LedgerSchema.modelCallKind), let state = try context.records.state(of: ref, scope: .vault) else { return [] }
    guard let entry = try Ledger.entries(ofCall: id, in: context.records).first, entry.id == id else { return [] }
    return [ModelCallIndexRow(entry: id, call: entry.parent ?? id, digest: RecordIndexDerivation.digest(of: state))]
  }
}

import Foundation
import GRDB
import ShadowStore

public struct VolumeStateEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_volume_state"

  public let key: EntityKey
  public let novel: UUID
  public let volume: String
  public let ordinal: Int
  public let state: VolumeState

  init(key: EntityKey, novel: UUID, volume: String, ordinal: Int, state: VolumeState) {
    self.key = key
    self.novel = novel
    self.volume = volume
    self.ordinal = ordinal
    self.state = state
  }

  public init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("a volume state holds an invalid key") }
    guard let state = VolumeState(rawValue: try row.decode(String.self, forColumn: "state")) else { throw StoreError.corruptStore("a volume state holds an unknown state") }
    self.init(
      key: key, novel: try row.decode(UUID.self, forColumn: "novel"), volume: try row.decode(String.self, forColumn: "volume"),
      ordinal: try row.decode(Int.self, forColumn: "ordinal"), state: state)
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.volume.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["volume"] = volume
    container["ordinal"] = ordinal
    container["state"] = state.rawValue
  }
}

// The reference stores a volume's state and a concurrent insert could activate two, so each device derives it from the goal-met registers.
public struct VolumeStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_volume_state (key TEXT PRIMARY KEY, novel BLOB NOT NULL, volume TEXT NOT NULL, ordinal INTEGER NOT NULL, state TEXT NOT NULL) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_volume_state_novel ON nf_derived_volume_state (novel, ordinal);
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: RecordIndexDerivation.self) { row in row.kind == .volume ? row.novel.map { [$0] } ?? [] : [] }]
  }

  public static func key(of output: VolumeStateEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<VolumeStateEntry> {
    VolumeStateEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(IndexedRecord.filter(Column("kind") == NovelForgeKind.volume)).compactMap(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [VolumeStateEntry] {
    var volumes = [VolumeRecord]()
    for row in try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.volume)) {
      guard case .readable(let entry) = try VolumeRecord.read(row.ref, in: context.records), !entry.isRemoved else { continue }
      volumes.append(entry.record)
    }
    return volumeStandings(of: volumes).map { standing in
      VolumeStateEntry(
        key: VolumeRecord.ref(novel: novel, volume: standing.volume).key, novel: novel, volume: standing.volume, ordinal: standing.ordinal, state: standing.state)
    }
  }
}

import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText

/// The final chapter in which the reader learned a secret (the reference's `canon_facts.disclosed_in_chapter`).
public struct ReaderDisclosureEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_reader_disclosure"

  public let novel: UUID
  public let secret: String
  public let chapter: Int

  init(novel: UUID, secret: String, chapter: Int) {
    self.novel = novel
    self.secret = secret
    self.chapter = chapter
  }

  public init(row: Row) throws {
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), secret: try row.decode(String.self, forColumn: "secret"),
      chapter: try row.decode(Int.self, forColumn: "chapter"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["secret"] = secret
    container["chapter"] = chapter
  }
}

extension EntityState {
  /// When the record last became live: `removed` is written only by a create, a restore or a removal, so a live record's clock is its last create or restore.
  var liveSince: HLCTimestamp? {
    guard case .record(let record) = self else { return nil }
    return record[field: CommonField.removed.rawValue]?.clock
  }
}

// apps/novel-forge-server/src/common/provisional-knowledge.ts:141: a secret is disclosed by the lowest final chapter whose canon recorded it, provided the secret was live
// when that canon was written, as finalize could mark only a row that existed; a secret removed and created again afterwards is a new row. A canon that recorded no
// set, or that this version cannot read, discloses nothing.
public struct ReaderDisclosureDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_reader_disclosure (
      novel BLOB NOT NULL, secret TEXT NOT NULL, chapter INTEGER NOT NULL, PRIMARY KEY (novel, secret)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: FinalChapterDerivation.self) { [$0.novel] },
      .outputs(of: RecordIndexDerivation.self) { row in row.kind == .secret ? row.novel.map { [$0] } ?? [] : [] },
    ]
  }

  public static func key(of output: ReaderDisclosureEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<ReaderDisclosureEntry> {
    ReaderDisclosureEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(FinalChapterEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [ReaderDisclosureEntry] {
    let finals = try context.fetchAll(FinalChapterEntry.filter(Column("novel") == novel)).sorted { $0.chapter < $1.chapter }
    var live = [JSString: HLCTimestamp?]()
    var disclosed = [JSString: ReaderDisclosureEntry]()
    for final in finals {
      guard let recorded = final.disclosed, let written = final.canonClock else { continue }
      let keys = try DisclosedColumn.decode(recorded)
      for key in keys where disclosed[JSString(key)] == nil {
        let slot = JSString(key)
        let since: HLCTimestamp?
        if let cached = live[slot] {
          since = cached
        } else {
          since = try Self.liveSince(novel: novel, secret: key, in: context)
          live.updateValue(since, forKey: slot)
        }
        guard let since, since <= written else { continue }
        disclosed[slot] = ReaderDisclosureEntry(novel: novel, secret: key, chapter: final.chapter)
      }
    }
    return Array(disclosed.values)
  }

  private static func liveSince(novel: UUID, secret: String, in context: DerivationContext) throws(StoreError) -> HLCTimestamp? {
    let ref = SecretRecord.ref(novel: novel, secret: secret)
    let state = try context.records.state(of: ref, scope: .vault)
    guard case .readable(let entry) = SecretRecord.reading(state, of: ref), !entry.isRemoved else { return nil }
    return state?.liveSince
  }
}

import Foundation
import GRDB
import ShadowStore

/// What the reader has been shown: each secret a final chapter disclosed, by key, with the first chapter that did. A consumer reads `.unavailable`, and a secret
/// missing because a final chapter or a secret is faulted on its own, as nothing disclosed: the secret stays a secret, which withholds more, never less.
public struct ReaderDisclosure: ReadModel {
  public let entries: Derived<[ReaderDisclosureEntry]>
  public let faults: [ReadFault]
  private let chapters: Derived<[JSString: Int]>

  private static let tables = [ReaderDisclosureEntry.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ReaderDisclosure {
    try load(novel, faults: try FaultRows(in: transaction), in: transaction)
  }

  static func load(_ novel: UUID, faults: FaultRows, in transaction: ReadTransaction) throws(StoreError) -> ReaderDisclosure {
    let report = ReadFaults(novel: novel, reading: tables, from: faults)
    let entries = try report.section(tables) { () throws(StoreError) in
      let rows = try transaction.query { database in try ReaderDisclosureEntry.filter(Column("novel") == novel).fetchAll(database) }
      return rows.sorted { JSText.codeUnitPrecedes($0.secret, $1.secret) }
    }
    return ReaderDisclosure(
      entries: entries, faults: report.relevant, chapters: entries.map { Dictionary($0.map { (JSString($0.secret), $0.chapter) }) { first, _ in first } })
  }
}

extension ReaderDisclosure {
  /// The chapter in which the reader learned `secret`, nil while it is still a secret to them.
  public func chapter(of secret: String) -> Derived<Int?> {
    chapters.map { $0[JSString(secret)] }
  }

  /// The secrets `chapter` disclosed.
  public func secrets(disclosedIn chapter: Int) -> Derived<[String]> {
    entries.map { entries in entries.filter { $0.chapter == chapter }.map(\.secret) }
  }

  /// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:160 (shownToReader): a chapter before `chapter` disclosed it.
  public func isShown(_ secret: String, before chapter: Int) -> Derived<Bool> {
    self.chapter(of: secret).map { disclosed in disclosed.map { $0 < chapter } ?? false }
  }
}

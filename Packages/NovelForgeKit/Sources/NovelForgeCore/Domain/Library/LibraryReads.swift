import Foundation
import ShadowCore
import ShadowStore

extension Library {
  // project.service.ts:139: the main list shows live, non-archived novels; archived ones are listed apart
  public static func novels<Transaction: StateReading & ~Copyable>(in transaction: borrowing Transaction) throws(DomainError) -> NovelList {
    try list(archived: false, in: transaction)
  }

  public static func archivedNovels<Transaction: StateReading & ~Copyable>(in transaction: borrowing Transaction) throws(DomainError) -> NovelList {
    try list(archived: true, in: transaction)
  }

  // project.service.ts:164
  public static func novel<Transaction: StateReading & ~Copyable>(_ novel: UUID, in transaction: borrowing Transaction) throws(DomainError) -> NovelRecord? {
    let ref = NovelForgeKey.novel(novel)
    let reading: RecordReading<NovelRecord>
    do throws(StoreError) {
      reading = try NovelRecord.read(id: novel, in: transaction)
    } catch {
      throw .store(error)
    }
    return try readable(reading, ref: ref)?.record
  }

  private static func list<Transaction: StateReading & ~Copyable>(archived: Bool, in transaction: borrowing Transaction) throws(DomainError) -> NovelList {
    let listing: RecordListing<NovelRecord>
    do throws(StoreError) {
      listing = try NovelRecord.listing(in: transaction)
    } catch {
      throw .store(error)
    }
    let novels = listing.live.filter { $0.archived == archived }.sorted {
      $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : JSText.codeUnitPrecedes($0.name, $1.name)
    }
    return NovelList(novels: novels, unreadable: listing.unreadable + listing.unattributed)
  }
}

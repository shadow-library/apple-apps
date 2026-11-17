import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct PageReading: ReadModel {
  struct Input: Sendable {
    let novel: UUID
    let address: PageAddress
  }

  enum Presence: Equatable, Sendable {
    case missing
    case removed(title: String)
    case unreadable
    case live(PageRecord)
  }

  let presence: Presence
  let versions: [PageVersion]

  static func load(_ input: Input, in transaction: ReadTransaction) throws(StoreError) -> PageReading {
    let address = input.address
    switch try PageRecord.read(novel: input.novel, section: address.section, slug: address.slug, in: transaction) {
    case .absent: return PageReading(presence: .missing, versions: [])
    case .unreadable: return PageReading(presence: .unreadable, versions: [])
    case .readable(let entry) where entry.isRemoved: return PageReading(presence: .removed(title: Pages.title(of: entry.record)), versions: [])
    case .readable(let entry): return PageReading(presence: .live(entry.record), versions: try versions(input, in: transaction))
    }
  }

  private static func versions(_ input: Input, in transaction: ReadTransaction) throws(StoreError) -> [PageVersion] {
    do throws(DomainError) {
      return try Pages.versions(novel: input.novel, section: input.address.section, slug: input.address.slug, in: transaction)
    } catch {
      if case .store(let store) = error { throw store }
      return []
    }
  }
}

extension PageVersion {
  var date: Date { Date(timeIntervalSince1970: TimeInterval(created.wallMillis) / 1000) }
}

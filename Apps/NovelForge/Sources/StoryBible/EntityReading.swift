import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct KnowledgeItem: Equatable, Sendable, Identifiable {
  let fact: String
  let text: String?
  let chapter: Int
  let status: KnowledgeStatus
  let source: FactSource

  var id: String { "\(chapter)/\(fact)" }
}

nonisolated struct EntityReading: ReadModel {
  struct Input: Sendable {
    let novel: UUID
    let entity: String
  }

  enum Presence: Equatable, Sendable {
    case missing
    case removed(name: String)
    case unreadable
    case live(EntityRecord)
  }

  let presence: Presence
  let knowledge: Derived<[KnowledgeItem]>?

  static func load(_ input: Input, in transaction: ReadTransaction) throws(StoreError) -> EntityReading {
    switch try EntityRecord.read(EntityRecord.ref(novel: input.novel, entity: input.entity), in: transaction) {
    case .absent: return EntityReading(presence: .missing, knowledge: nil)
    case .unreadable: return EntityReading(presence: .unreadable, knowledge: nil)
    case .readable(let entry) where entry.isRemoved: return EntityReading(presence: .removed(name: entry.record.name), knowledge: nil)
    case .readable(let entry):
      guard entry.record.type == .known(.character) else { return EntityReading(presence: .live(entry.record), knowledge: nil) }
      return EntityReading(presence: .live(entry.record), knowledge: try knowledge(of: entry.record, in: transaction))
    }
  }

  private static func knowledge(of entity: EntityRecord, in transaction: ReadTransaction) throws(StoreError) -> Derived<[KnowledgeItem]> {
    let ledger = try KnowledgeLedger.load(entity.novel, in: transaction)
    switch ledger.facts(known: entity.entity) {
    case .unavailable(let faults): return .unavailable(faults)
    case .available(let entries):
      var items = [KnowledgeItem]()
      for entry in entries {
        let text = try secretText(novel: entity.novel, fact: entry.fact, in: transaction)
        items.append(KnowledgeItem(fact: entry.fact, text: text, chapter: entry.chapter, status: entry.status, source: entry.source))
      }
      return .available(items)
    }
  }

  private static func secretText(novel: UUID, fact: String, in transaction: ReadTransaction) throws(StoreError) -> String? {
    guard case .readable(let entry) = try SecretRecord.read(SecretRecord.ref(novel: novel, secret: fact), in: transaction), !entry.isRemoved else { return nil }
    return entry.record.text
  }
}

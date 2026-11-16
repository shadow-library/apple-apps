import Foundation
import ShadowCore
import ShadowStore

enum BiblePresence<Record: Sendable & Equatable>: Sendable {
  case absent
  case removed(Record)
  case live(Record)
}

func requireBibleKey(_ key: String, field: String) throws(BibleError) {
  guard !key.isEmpty else { throw .invalidKey(field: field) }
}

func requireBibleText(_ text: String, field: String) throws(BibleError) {
  guard !text.jsTrim().isEmpty else { throw .blank(field: field) }
}

extension WriteTransaction {
  func biblePresence<Record: NovelForgeRecord>(_ ref: EntityRef, as _: Record.Type) throws(BibleError) -> BiblePresence<Record> {
    let reading: RecordReading<Record>
    do throws(StoreError) {
      reading = try Record.read(ref, in: self)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent: return .absent
    case .unreadable: throw .unreadable(ref)
    case .readable(let entry): return entry.isRemoved ? .removed(entry.record) : .live(entry.record)
    }
  }

  func requireBibleNovel(_ novel: UUID) throws(BibleError) {
    guard case .live = try biblePresence(NovelForgeKey.novel(novel), as: NovelRecord.self) else { throw .novelNotFound(novel) }
  }

  mutating func bibleCreate(_ record: some NovelForgeRecord) throws(BibleError) {
    do throws(StoreError) {
      _ = try record.create(in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func bibleRestore(_ record: some RemovableRecord) throws(BibleError) {
    do throws(StoreError) {
      _ = try record.restore(in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func bibleEdit<Record: NovelForgeRecord>(_: Record.Type, _ ref: EntityRef, _ fields: RecordFields<Record.Field>) throws(BibleError) {
    guard !fields.members.isEmpty else { return }
    do throws(StoreError) {
      _ = try Record.edit(ref, fields, in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func bibleRemove<Record: RemovableRecord>(_: Record.Type, _ ref: EntityRef) throws(BibleError) {
    do throws(StoreError) {
      _ = try Record.remove(ref, in: &self)
    } catch {
      throw .store(error)
    }
  }
}

func bibleReading<Record: Sendable & Equatable>(_ reading: RecordReading<Record>, ref: EntityRef) throws(BibleError) -> RecordEntry<Record>? {
  switch reading {
  case .absent: nil
  case .unreadable: throw .unreadable(ref)
  case .readable(let entry): entry
  }
}

import Foundation
import ShadowCore
import ShadowStore
import ShadowText

extension VaultStore {
  public func writeDomain<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(DomainError) -> T) async throws(DomainError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let domain = cause as? DomainError { throw domain }
      throw .store(error)
    }
  }
}

enum Presence<Record: Sendable & Equatable>: Sendable {
  case absent
  case removed(Record)
  case live(Record)
}

func requireKey(_ key: String, field: String) throws(DomainError) {
  guard !key.isEmpty else { throw .invalidKey(field: field) }
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:16 pins keys to /^\S+$/
func requireSpacelessKey(_ key: String, field: String) throws(DomainError) {
  guard !key.isEmpty, !key.unicodeScalars.contains(where: JSText.isWhitespace) else { throw .invalidKey(field: field) }
}

func requireNonBlank(_ text: String, field: String) throws(DomainError) {
  guard !text.jsTrim().isEmpty else { throw .blank(field: field) }
}

func requireAtMost(_ text: String, _ limit: Int, field: String) throws(DomainError) {
  guard text.unicodeScalars.count <= limit else { throw .tooLong(field: field, limit: limit) }
}

func requireAtLeast(_ value: Int, _ minimum: Int, field: String) throws(DomainError) {
  guard value >= minimum else { throw .belowMinimum(field: field, minimum: minimum) }
}

extension WriteTransaction {
  func presence<Record: NovelForgeRecord>(_ ref: EntityRef, as _: Record.Type) throws(DomainError) -> Presence<Record> {
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

  func listing<Record: KeyedRecord>(_: Record.Type, novel: UUID) throws(DomainError) -> [Record] {
    do throws(StoreError) {
      return try Record.listing(novel: novel, in: self).live
    } catch {
      throw .store(error)
    }
  }

  func requireNovel(_ novel: UUID) throws(DomainError) {
    let ref = NovelForgeKey.novel(novel)
    guard case .live = try presence(ref, as: NovelRecord.self) else { throw .novelNotFound(novel) }
  }

  mutating func create(_ record: some NovelForgeRecord) throws(DomainError) {
    do throws(StoreError) {
      _ = try record.create(in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func restore(_ record: some RemovableRecord) throws(DomainError) {
    do throws(StoreError) {
      _ = try record.restore(in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func edit<Record: NovelForgeRecord>(_: Record.Type, _ ref: EntityRef, _ fields: RecordFields<Record.Field>) throws(DomainError) {
    guard !fields.members.isEmpty else { return }
    do throws(StoreError) {
      _ = try Record.edit(ref, fields, in: &self)
    } catch {
      throw .store(error)
    }
  }

  mutating func remove<Record: RemovableRecord>(_: Record.Type, _ ref: EntityRef) throws(DomainError) {
    do throws(StoreError) {
      _ = try Record.remove(ref, in: &self)
    } catch {
      throw .store(error)
    }
  }
}

func readable<Record: Sendable & Equatable>(_ reading: RecordReading<Record>, ref: EntityRef) throws(DomainError) -> RecordEntry<Record>? {
  switch reading {
  case .absent: nil
  case .unreadable: throw .unreadable(ref)
  case .readable(let entry): entry
  }
}

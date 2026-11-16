import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

enum Harness {
  static let commonMembers: Set<String> = ["natural_key", "removed"]

  static let newerMember = "added_by_a_newer_version"

  static func newerVersionStore() throws -> VaultStore {
    let entities = NovelForgeSchema.entities.map { schema in
      guard case .record(let fields) = schema.shape else { return schema }
      return EntitySchema(kind: schema.kind, shape: .record(fields: fields.merging([newerMember: .register]) { first, _ in first }), syncClass: schema.syncClass)
    }
    return try VaultStore.open(.inMemory, registry: SchemaRegistry(version: NovelForgeSchema.version, entities: entities))
  }

  static func memberNames<S: RecordSubject>(_: S.Type) -> Set<String> {
    let names = Set(S.Record.Field.allCases.map(\.rawValue))
    return S.Record.self is any RemovableRecord.Type ? names.union(commonMembers) : names
  }

  static func read<R: NovelForgeRecord>(_ ref: EntityRef, as _: R.Type, in store: VaultStore) async throws -> RecordReading<R> {
    try await store.read { transaction in try R.read(ref, in: transaction) }
  }

  static func create<R: NovelForgeRecord>(_ record: R, in store: VaultStore) async throws -> ChangeRecord {
    try await store.write { transaction in try record.create(in: &transaction) }
  }

  static func perform<R>(_ edit: SubjectEdit<R>, in store: VaultStore) async throws -> ChangeRecord {
    let perform = edit.perform
    return try await store.write { transaction in try perform(&transaction) }
  }

  static func remove<R: RemovableRecord>(_ record: R, in store: VaultStore) async throws -> ChangeRecord {
    let ref = record.ref
    return try await store.write { transaction in try R.remove(ref, in: &transaction) }
  }

  static func restore<R: RemovableRecord>(_ record: R, in store: VaultStore) async throws -> ChangeRecord {
    try await store.write { transaction in try record.restore(in: &transaction) }
  }
}

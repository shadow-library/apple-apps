import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowSync

@Suite("SyncKernelSchema")
struct SyncKernelSchemaTests {
  @Test("should build a registry holding the kernel kinds and the app's kinds")
  func shouldBuildRegistry() {
    let registry = ReplicaFixture.registry
    #expect(registry.version == 3)
    #expect(registry[ReplicaFixture.note] != nil)
    for schema in SyncKernelSchema.entities { #expect(registry[schema.kind] == schema) }
  }

  @Test("should trap when an app kind takes the reserved prefix or a kernel kind's name")
  func shouldTrapOnClash() async {
    await #expect(processExitsWith: .failure) {
      guard let kind = EntityKind("_replica") else { return }
      _ = SyncKernelSchema.registry(version: 1, adding: [EntitySchema(kind: kind, shape: .record(fields: [:]), syncClass: .general)])
    }
    await #expect(processExitsWith: .failure) {
      guard let kind = EntityKind("_mine") else { return }
      _ = SyncKernelSchema.registry(version: 1, adding: [EntitySchema(kind: kind, shape: .record(fields: [:]), syncClass: .general)])
    }
  }

  @Test("should be an additive successor of itself and of a registry without app kinds")
  func shouldBeAdditive() {
    let kernel = SyncKernelSchema.registry(version: 1, adding: [])
    #expect(kernel.incompatibilities(with: kernel).isEmpty)
    #expect(ReplicaFixture.registry.incompatibilities(with: kernel).isEmpty)
    #expect(ReplicaFixture.registry.incompatibilities(with: ReplicaFixture.registry).isEmpty)
  }

  @Test("should keep the synced kinds and field names exactly as pinned")
  func shouldPinFormat() {
    let lifecycle = FieldRule.monotone(order: ["active", "retired"])
    let pinned: [EntitySchema] = [
      EntitySchema(
        kind: ReplicaFixture.kind("_replica"),
        shape: .record(fields: ["state": lifecycle, "name": .register, "platform": .register, "successor": .register, "created": .firstWriterWins]), syncClass: .general),
      EntitySchema(kind: ReplicaFixture.kind("_schema_floor"), shape: .record(fields: ["version": .firstWriterWins]), syncClass: .general),
      EntitySchema(kind: ReplicaFixture.kind("_key_floor"), shape: .record(fields: ["key": .firstWriterWins]), syncClass: .general),
      EntitySchema(
        kind: ReplicaFixture.kind("_recovery"),
        shape: .record(fields: ["public_key": .firstWriterWins, "sealing_key": .firstWriterWins, "state": lifecycle, "created": .firstWriterWins]),
        syncClass: .general),
      EntitySchema(
        kind: ReplicaFixture.kind("_adoption"), shape: .record(fields: ["through": .firstWriterWins, "at": .firstWriterWins, "base_up_to": .firstWriterWins]),
        syncClass: .general),
    ]
    #expect(SyncKernelSchema.entities == pinned)
  }

  @Test("should carry floor values in their keys and derive the other keys as pinned")
  func shouldPinKeys() throws {
    #expect(SyncKernelSchema.schemaFloorRef(7) == EntityRef(kind: ReplicaFixture.kind("_schema_floor"), key: ReplicaFixture.key("v-7")))
    #expect(SyncKernelSchema.schemaFloorRef(0).key.rawValue == "v-0")
    let keyID = try #require(KeyID("01936f3e-0000-7000-8000-000000000001"))
    #expect(SyncKernelSchema.keyFloorRef(keyID) == EntityRef(kind: ReplicaFixture.kind("_key_floor"), key: ReplicaFixture.key("01936f3e-0000-7000-8000-000000000001")))
    let recovery = EntityKey.natural(scope: "shadow.sync", kind: ReplicaFixture.kind("_recovery"), components: ["0123456789abcdef"])
    #expect(SyncKernelSchema.recoveryRef("0123456789abcdef").key == recovery)
    let replica = ReplicaFixture.replica("01936f3e-1111-7111-8111-111111111111")
    #expect(SyncKernelSchema.replicaRef(replica).key.rawValue == replica.description)
  }

  @Test("should read a schema floor only from a canonical key", arguments: ["v-", "v-07", "v--1", "x-5", "v-5a", "v-99999999999999999999999"])
  func shouldRejectMalformedFloorKeys(_ text: String) {
    #expect(SyncKernelSchema.schemaFloor(of: ReplicaFixture.key(text)) == nil)
  }
}

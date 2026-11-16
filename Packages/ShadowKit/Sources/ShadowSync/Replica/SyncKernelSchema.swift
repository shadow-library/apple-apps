import Foundation
import ShadowCore
import ShadowStore

public enum SyncKernelSchema {
  static let reservedPrefix = "_"
  static let naturalScope = "shadow.sync"
  static let schemaFloorPrefix = "v-"
  static let lifecycleOrder = [ReplicaState.active.rawValue, ReplicaState.retired.rawValue]

  static let replicaKind = kind("_replica")
  static let schemaFloorKind = kind("_schema_floor")
  static let keyFloorKind = kind("_key_floor")
  static let recoveryKind = kind("_recovery")

  enum Field {
    static let state = "state"
    static let name = "name"
    static let platform = "platform"
    static let successor = "successor"
    static let created = "created"
    static let version = "version"
    static let key = "key"
    static let publicKey = "public_key"
    static let sealingKey = "sealing_key"
  }

  public static let entities: [EntitySchema] = [
    EntitySchema(
      kind: replicaKind,
      shape: .record(fields: [
        Field.state: .monotone(order: lifecycleOrder), Field.name: .register, Field.platform: .register, Field.successor: .register, Field.created: .firstWriterWins,
      ]),
      syncClass: .general),
    EntitySchema(kind: schemaFloorKind, shape: .record(fields: [Field.version: .firstWriterWins]), syncClass: .general),
    EntitySchema(kind: keyFloorKind, shape: .record(fields: [Field.key: .firstWriterWins]), syncClass: .general),
    EntitySchema(
      kind: recoveryKind,
      shape: .record(fields: [
        Field.publicKey: .firstWriterWins, Field.sealingKey: .firstWriterWins, Field.state: .monotone(order: lifecycleOrder), Field.created: .firstWriterWins,
      ]),
      syncClass: .general),
  ]

  public static func registry(version: Int, adding appEntities: [EntitySchema]) -> SchemaRegistry {
    for schema in appEntities {
      precondition(!schema.kind.rawValue.hasPrefix(reservedPrefix), "App kind \(schema.kind) starts with \(reservedPrefix), which is reserved for the sync kernel")
    }
    return SchemaRegistry(version: version, entities: entities + appEntities)
  }

  static func replicaRef(_ replica: ReplicaID) -> EntityRef {
    guard let key = EntityKey(replica.description) else { preconditionFailure("a replica id is a valid entity key") }
    return EntityRef(kind: replicaKind, key: key)
  }

  static func schemaFloorRef(_ version: Int) -> EntityRef {
    EntityRef(kind: schemaFloorKind, key: key(schemaFloorPrefix + String(version)))
  }

  static func keyFloorRef(_ keyID: KeyID) -> EntityRef {
    EntityRef(kind: keyFloorKind, key: key(keyID.description))
  }

  static func schemaFloor(of key: EntityKey) -> Int? {
    guard key.rawValue.hasPrefix(schemaFloorPrefix) else { return nil }
    let digits = key.rawValue.dropFirst(schemaFloorPrefix.count)
    guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }), digits == "0" || !digits.hasPrefix("0"), let version = Int(digits) else { return nil }
    return version
  }

  static func keyFloor(of key: EntityKey) -> KeyID? {
    KeyID(key.rawValue)
  }

  static func recoveryRef(_ recipientID: String) -> EntityRef {
    naturalRef(recoveryKind, recipientID)
  }

  private static func naturalRef(_ kind: EntityKind, _ component: String) -> EntityRef {
    EntityRef(kind: kind, key: EntityKey.natural(scope: naturalScope, kind: kind, components: [component]))
  }

  private static func key(_ text: String) -> EntityKey {
    guard let key = EntityKey(text) else { preconditionFailure("\(text) is a valid entity key") }
    return key
  }

  private static func kind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("\(name) is a valid entity kind") }
    return kind
  }
}

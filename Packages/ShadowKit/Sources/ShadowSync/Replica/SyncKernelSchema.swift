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
  static let adoptionKind = kind("_adoption")
  static let kinds = [replicaKind, schemaFloorKind, keyFloorKind, recoveryKind, adoptionKind]

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
    static let through = "through"
    static let at = "at"
    static let baseUpTo = "base_up_to"
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
    EntitySchema(
      kind: adoptionKind, shape: .record(fields: [Field.through: .firstWriterWins, Field.at: .firstWriterWins, Field.baseUpTo: .firstWriterWins]),
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

  /// `<adopted>:<adopter>:<through>:<at>:<baseUpTo>`, decimals without leading zeros, so one fact has exactly one key.
  static func adoptionRef(_ fact: SyncAdoptionFact) -> EntityRef {
    let numbers = [fact.through, fact.at, fact.baseUpTo].map(String.init)
    return EntityRef(kind: adoptionKind, key: key(([fact.adopted.description, fact.adopter.description] + numbers).joined(separator: ":")))
  }

  static func adoption(of key: EntityKey) -> SyncAdoptionFact? {
    let components = key.rawValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard components.count == 5, let adopted = ReplicaID(components[0]), let adopter = ReplicaID(components[1]), adopted != adopter else { return nil }
    guard let through = canonicalSequence(components[2]), let at = canonicalSequence(components[3]), at >= 1, let baseUpTo = canonicalSequence(components[4]) else {
      return nil
    }
    let fact = SyncAdoptionFact(adopted: adopted, adopter: adopter, through: through, at: at, baseUpTo: baseUpTo)
    return adoptionRef(fact).key == key ? fact : nil
  }

  private static func canonicalSequence(_ digits: String) -> Int64? {
    guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }), digits == "0" || !digits.hasPrefix("0"), digits.count <= 12, let value = Int64(digits) else { return nil }
    return value <= VaultPath.maximumSequence ? value : nil
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

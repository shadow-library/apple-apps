import Foundation
import ShadowCore
import ShadowStore

extension VolumeField: FieldName {}

public struct VolumeRecord: RemovableRecord {
  public static let kind = NovelForgeKind.volume

  public let key: NovelForgeKey
  public let volume: String
  public var ordinal: Int
  public var title: String?
  public var objective: String?
  public var body: String?
  public var goalMet: Bool

  public init(novel: UUID, volume: String, ordinal: Int, title: String? = nil, objective: String? = nil, body: String? = nil, goalMet: Bool = false) {
    let volume = volume.precomposedStringWithCanonicalMapping
    self.volume = volume
    key = .volumeKey(novel: novel, volume: volume)
    self.ordinal = ordinal
    self.title = title
    self.objective = objective
    self.body = body
    self.goalMet = goalMet
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<VolumeField>) throws(UnreadableReason) {
    guard case .volume(let volume) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, volume: volume, ordinal: try reader.required(.ordinal), title: try reader.optional(.title), objective: try reader.optional(.objective),
      body: try reader.optional(.body), goalMet: try reader.required(.goalMet))
  }

  public var fields: RecordFields<VolumeField> {
    var fields = RecordFields<VolumeField>()
    fields.put(.ordinal, ordinal)
    fields.put(.title, title)
    fields.put(.objective, objective)
    fields.put(.body, body)
    fields.put(.goalMet, goalMet)
    return fields
  }
}

public struct VolumeEdit: Sendable, Equatable {
  public var ordinal: FieldChange<Int> = .keep
  public var title: FieldChange<String?> = .keep
  public var objective: FieldChange<String?> = .keep
  public var body: FieldChange<String?> = .keep
  public var goalMet: FieldChange<Bool> = .keep

  public init() {}

  public var fields: RecordFields<VolumeField> {
    var fields = RecordFields<VolumeField>()
    fields.put(.ordinal, ordinal)
    fields.put(.title, title)
    fields.put(.objective, objective)
    fields.put(.body, body)
    fields.put(.goalMet, goalMet)
    return fields
  }
}

extension VolumeRecord {
  public static func ref(novel: UUID, volume: String) -> EntityRef { NovelForgeKey.volume(novel: novel, key: volume) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, volume: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    VolumeRecord
  > {
    try read(ref(novel: novel, volume: volume), in: transaction)
  }

  public static func edit(novel: UUID, volume: String, _ changes: VolumeEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, volume: volume), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, volume: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, volume: volume), in: &transaction)
  }
}

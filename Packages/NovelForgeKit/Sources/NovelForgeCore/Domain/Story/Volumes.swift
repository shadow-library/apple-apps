import Foundation
import ShadowStore
import ShadowText

public struct VolumeChanges: Sendable, Equatable {
  public var ordinal: FieldChange<Int> = .keep
  public var title: FieldChange<String?> = .keep
  public var objective: FieldChange<String?> = .keep
  public var body: FieldChange<String?> = .keep

  public init(ordinal: FieldChange<Int> = .keep, title: FieldChange<String?> = .keep, objective: FieldChange<String?> = .keep, body: FieldChange<String?> = .keep) {
    self.ordinal = ordinal
    self.title = title
    self.objective = objective
    self.body = body
  }
}

public struct VolumeAdvance: Sendable, Equatable {
  public let completed: String
  public let activated: String?
}

// apps/novel-forge-server/src/database/schemas/plan.ts:27 holds the title to 500 characters
private let volumeTitleLimit = 500

// apps/novel-forge-server/src/modules/refinement/apply/volume.handler.ts, apps/novel-forge-server/src/modules/bible/volume/volume.service.ts
public enum Volumes {
  public static func create(
    novel: UUID, volume: String, ordinal: Int? = nil, title: String? = nil, objective: String? = nil, body: String? = nil, in transaction: inout WriteTransaction
  ) throws(DomainError) {
    try requireKey(volume, field: "volumeKey")
    try requireTitle(title)
    try transaction.requireNovel(novel)
    let highest = try transaction.listing(VolumeRecord.self, novel: novel).map(\.ordinal).max()
    let placed = ordinal ?? highest.map { $0 == Int.max ? $0 : $0 + 1 } ?? 0
    let record = VolumeRecord(novel: novel, volume: volume, ordinal: placed, title: title, objective: objective, body: body)
    if case .live = try transaction.presence(record.ref, as: VolumeRecord.self) { throw .volumeExists(record.volume) }
    try transaction.create(record)
  }

  public static func edit(novel: UUID, volume: String, _ changes: VolumeChanges, in transaction: inout WriteTransaction) throws(DomainError) {
    try requireKey(volume, field: "volumeKey")
    if case .set(let title) = changes.title { try requireTitle(title) }
    let ref = VolumeRecord.ref(novel: novel, volume: volume)
    guard case .live = try transaction.presence(ref, as: VolumeRecord.self) else { throw .volumeNotFound(volume) }
    var edit = VolumeEdit()
    edit.ordinal = changes.ordinal
    edit.title = changes.title
    edit.objective = changes.objective
    edit.body = changes.body
    try transaction.edit(VolumeRecord.self, ref, edit.fields)
  }

  // volume.handler.ts:51 refuses while a chapter plan still names the volume
  public static func remove(novel: UUID, volume: String, in transaction: inout WriteTransaction) throws(DomainError) {
    let ref = VolumeRecord.ref(novel: novel, volume: volume)
    guard case .live(let record) = try transaction.presence(ref, as: VolumeRecord.self) else { throw .volumeNotFound(volume) }
    let planned = try transaction.listing(ChapterPlanRecord.self, novel: novel).filter { $0.content.volume?.jsEquals(record.volume) == true }.map(\.chapter).min()
    if let planned { throw .volumeInPlan(volume: record.volume, chapter: planned) }
    try transaction.remove(VolumeRecord.self, ref)
  }

  public static func restore(novel: UUID, volume: String, in transaction: inout WriteTransaction) throws(DomainError) {
    switch try transaction.presence(VolumeRecord.ref(novel: novel, volume: volume), as: VolumeRecord.self) {
    case .removed(let record): try transaction.restore(record)
    case .live: return
    case .absent: throw .volumeNotFound(volume)
    }
  }

  // volume.service.ts:101: only the active volume can be completed; the next volume becomes active by derivation, never by a write
  public static func markGoalMet(novel: UUID, volume: String, in transaction: inout WriteTransaction) throws(DomainError) -> VolumeAdvance {
    let ref = VolumeRecord.ref(novel: novel, volume: volume)
    guard case .live(let target) = try transaction.presence(ref, as: VolumeRecord.self) else { throw .volumeNotFound(volume) }
    let volumes = try transaction.listing(VolumeRecord.self, novel: novel)
    guard activeVolume(of: volumes) == target.volume else { throw .volumeNotActive(target.volume) }
    var edit = VolumeEdit()
    edit.goalMet = .set(true)
    try transaction.edit(VolumeRecord.self, ref, edit.fields)
    var completed = target
    completed.goalMet = true
    let after = volumes.map { $0.ref == ref ? completed : $0 }
    return VolumeAdvance(completed: target.volume, activated: activeVolume(of: after))
  }

  private static func requireTitle(_ title: String?) throws(DomainError) {
    guard let title else { return }
    try requireAtMost(title, volumeTitleLimit, field: "title")
  }
}

import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct StoryService: Sendable {
  let store: VaultStore
  let novel: UUID

  func createVolume(key: String, title: String?, objective: String?, body: String?) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      try Volumes.create(novel: novel, volume: key, title: title, objective: objective, body: body, in: &transaction)
    }
  }

  func editVolume(key: String, _ changes: VolumeChanges) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Volumes.edit(novel: novel, volume: key, changes, in: &transaction) }
  }

  func removeVolume(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Volumes.remove(novel: novel, volume: key, in: &transaction) }
  }

  func restoreVolume(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Volumes.restore(novel: novel, volume: key, in: &transaction) }
  }

  func markGoalMet(key: String) async throws(DomainError) -> VolumeAdvance {
    let novel = novel
    return try await store.writeDomain { transaction throws(DomainError) in try Volumes.markGoalMet(novel: novel, volume: key, in: &transaction) }
  }

  func moveVolumes(_ move: VolumeMove) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      let current = try Self.liveVolumes(novel: novel, in: transaction).sorted { left, right in
        guard left.ordinal == right.ordinal else { return left.ordinal < right.ordinal }
        return left.volume.utf16.lexicographicallyPrecedes(right.volume.utf16)
      }
      let keys = current.map(\.volume)
      let arranged = move.applied(to: keys)
      guard arranged != keys else { return }
      let ordinals = current.map(\.ordinal)
      let slots = Set(ordinals).count == ordinals.count ? ordinals : Array(ordinals.indices)
      let previous = Dictionary(uniqueKeysWithValues: current.map { ($0.volume, $0.ordinal) })
      for (key, slot) in zip(arranged, slots) where previous[key] != slot {
        try Volumes.edit(novel: novel, volume: key, VolumeChanges(ordinal: .set(slot)), in: &transaction)
      }
    }
  }

  func createMilestone(key: String, label: String, subject: String?, kind: MilestoneKind) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      try Milestones.create(novel: novel, milestone: key, label: label, subject: subject, kind: .known(kind), in: &transaction)
    }
  }

  func editMilestone(key: String, _ changes: MilestoneChanges) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Milestones.edit(novel: novel, milestone: key, changes, in: &transaction) }
  }

  func removeMilestone(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Milestones.remove(novel: novel, milestone: key, in: &transaction) }
  }

  func restoreMilestone(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Milestones.restore(novel: novel, milestone: key, in: &transaction) }
  }

  func createPromise(_ promise: PromiseRef, label: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Promises.create(novel: novel, promise, label: label, in: &transaction) }
  }

  func updatePromise(_ promise: PromiseRef, label: String?, settlement: PromiseSettlement?) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      try Promises.update(novel: novel, promise, label: label, settlement: settlement, in: &transaction)
    }
  }

  func dropPromise(_ promise: PromiseRef) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Promises.drop(novel: novel, promise, in: &transaction) }
  }

  func removePromise(_ promise: PromiseRef) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Promises.remove(novel: novel, promise, in: &transaction) }
  }

  func restorePromise(_ promise: PromiseRef) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Promises.restore(novel: novel, promise, in: &transaction) }
  }

  func saveSecret(key: String, text: String, _ changes: SecretChanges) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Secrets.upsert(novel: novel, secret: key, text: text, changes, in: &transaction) }
  }

  func removeSecret(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Secrets.remove(novel: novel, secret: key, in: &transaction) }
  }

  func restoreSecret(key: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try Secrets.restore(novel: novel, secret: key, in: &transaction) }
  }

  func reveal(secret: String, to entity: String, chapter: Int, note: String?) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in
      try ManualReveals.reveal(novel: novel, secret: secret, entity: entity, chapter: chapter, note: note, in: &transaction)
    }
  }

  func retract(secret: String, from entity: String) async throws(DomainError) {
    let novel = novel
    try await store.writeDomain { transaction throws(DomainError) in try ManualReveals.retract(novel: novel, secret: secret, entity: entity, in: &transaction) }
  }
}

nonisolated extension StoryService {
  fileprivate static func liveVolumes(novel: UUID, in transaction: borrowing WriteTransaction) throws(DomainError) -> [VolumeRecord] {
    do {
      return try VolumeRecord.listing(novel: novel, in: transaction).live
    } catch {
      throw .store(error)
    }
  }
}

nonisolated enum VolumeMove: Sendable, Equatable {
  case step(key: String, by: Int)
  case relocate(keys: [String], before: String?)

  func applied(to order: [String]) -> [String] {
    switch self {
    case .step(let key, let offset):
      guard let index = order.firstIndex(of: key), order.indices.contains(index + offset) else { return order }
      var result = order
      result.swapAt(index, index + offset)
      return result
    case .relocate(let keys, let anchor):
      let moving = order.filter { keys.contains($0) }
      var rest = order.filter { !keys.contains($0) }
      guard let anchor else { return rest + moving }
      guard let index = rest.firstIndex(of: anchor) else { return order }
      rest.insert(contentsOf: moving, at: index)
      return rest
    }
  }
}

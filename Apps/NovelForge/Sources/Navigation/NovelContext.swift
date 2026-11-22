import Foundation
import NovelForgeCore
import ShadowStore

struct NovelContext: Sendable {
  let store: VaultStore
  let novel: UUID
  /// This device's, which the card writes read when they decide on unrestricted writing.
  let ageGate: AgeGate

  init(store: VaultStore, novel: UUID, ageGate: AgeGate = AgeGate(passed: false)) {
    self.store = store
    self.novel = novel
    self.ageGate = ageGate
  }
}

import Foundation
import ShadowStore

struct NovelContext: Sendable {
  let store: VaultStore
  let novel: UUID
}
